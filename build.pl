#!/usr/bin/env perl
# Builds the Vaquero RV Park website from index.html (the single source file).
#
#   perl build.pl                       -> dist/ (the site to deploy) + the standalone email copy
#   SITE_URL=https://example.com perl build.pl
#
# Outputs:
#   dist/index.html                          the live site, photos as separate files
#   dist/photos/                             copied photos
#   dist/robots.txt, dist/sitemap.xml        search-engine files
#   Vaquero-RV-Park-Website-Prototype.html   one self-contained file, for emailing
use strict; use warnings; use MIME::Base64; use File::Path qw(make_path); use File::Copy qw(copy); use JSON::PP;

my $SITE_URL = $ENV{SITE_URL} || 'https://vaquerorvpark.com';
$SITE_URL =~ s{/$}{};
my $TITLE = 'Vaquero RV Park in Pleasanton, TX | Monthly RV Lots &amp; Rentals';
my $DESC  = 'Long-term RV lots, park-owned RVs and tiny homes in Pleasanton, Texas. '
          . 'Lots from $400/month, free Wi-Fi, 24-hour surveillance, cats and small dogs welcome. Minutes from H-E-B.';

open my $fh, '<:raw', 'index.html' or die "index.html: $!";
my $src = do { local $/; <$fh> }; close $fh;

# The source is authored for Claude Artifacts: head content first, then the page markup.
my ($head, $body) = $src =~ m{\A(.*?</style>)\s*(.*)\z}s or die "could not split head/body";

my $meta = <<"HTML";
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<link rel="canonical" href="$SITE_URL/">
<meta name="theme-color" content="#2B1A10">
<link rel="icon" href="photos/app-icon.png">
<link rel="apple-touch-icon" href="photos/app-icon.png">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Vaquero RV Park">
<meta property="og:title" content="$TITLE">
<meta property="og:description" content="$DESC">
<meta property="og:url" content="$SITE_URL/">
<meta property="og:image" content="$SITE_URL/photos/aerial-hero.jpg">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="$TITLE">
<meta name="twitter:description" content="$DESC">
<meta name="twitter:image" content="$SITE_URL/photos/aerial-hero.jpg">
<link rel="preload" as="image" href="photos/aerial-hero.jpg" fetchpriority="high">
<style>body{margin:0}img{max-width:100%}[hidden]{display:none!important}</style>
HTML

# --- site facts, read from the SITE and SPECIAL blocks in index.html ------------
# The landing pages and the static FAQ are filled from these, so a price or an open lot
# changes in one place only (index.html, which follows operations/rent-roll.md).
sub h { my $s = shift // ''; $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; $s =~ s/"/&quot;/g; $s }
sub j { my $s = shift // ''; $s =~ s/(["\\])/\\$1/g; $s }
sub money { my $n = shift; 1 while $n =~ s/^(\d+)(\d{3})/$1,$2/; "\$$n" }

my ($PHONE)   = $src =~ m{\bphone: "([^"]+)"} or die "SITE.phone not found";
my ($TELHREF) = $src =~ m{\bphoneHref: "([^"]+)"} or die "SITE.phoneHref not found";
my ($UTIL) = $src =~ m{\butilities: "([^"]+)"} or die "SITE.utilities not found";
my (%type, @types);
while ($src =~ m{\{ id: "(\w+)",\s*name: "([^"]*)",\s*desc: "([^"]*)",\s*rent: (null|\d+)(, from: true)? \}}g) {
  push @types, $1;
  $type{$1} = { name => $2, desc => $3, rent => ($4 eq 'null' ? undef : $4), from => $5 ? 1 : 0 };
}
die "SITE.rentalTypes not found" unless @types;
my ($faqblock) = $src =~ m{\bfaq: \[(.*?)\]\s*\};}s or die "SITE.faq not found";
my @faq;
while ($faqblock =~ m{\["((?:[^"\\]|\\.)*)",\s*"((?:[^"\\]|\\.)*)"\]}g) {
  my ($q, $a) = ($1, $2); s/\\(.)/$1/g for $q, $a; push @faq, [$q, $a];
}
my ($specblock) = $src =~ m{const SPECIAL = \{(.*?)\n\};}s or die "SPECIAL not found";
my @open;
for (split /\n/, $specblock) {
  next unless m{^\s*([\d.]+): \{ status:"(\w+)", type:"(\w+)",(?: ph:(\d+),)? rent:(\d+), deposit:(\d+), desc:"([^"]*)", features:\[([^\]]*)\]};
  my @c = ($1, $2, $3, $4, $5, $6, $7, $8);   # copy first: the features match below resets $1..$8
  push @open, { id => $c[0], status => $c[1], type => $c[2], ph => $c[3] || 0, rent => $c[4], deposit => $c[5],
                desc => $c[6], features => [ $c[7] =~ m{"([^"]*)"}g ] };
}

# drive times: SITE.nearby is the only source; the homepage list, /nearby-towns/ and the lede all follow it
my ($CHECKED) = $src =~ m{\bnearbyChecked: "([^"]+)"} or die "SITE.nearbyChecked not found";
my ($nearblock) = $src =~ m{\bnearby: \[(.*?)\n  \],}s or die "SITE.nearby not found";
my @near;
while ($nearblock =~ m{\{ name: "([^"]+)", addr: "([^"]+)", mi: "([\d.]+)", min: (\d+)(?:, town: "([^"]+)")? \}}g) {
  push @near, { name => $1, addr => $2, mi => $3, min => $4, town => $5 };
}
@near or die "SITE.nearby: no entries parsed";
my ($sa) = grep { $_->{name} eq 'Downtown San Antonio' } @near or die "nearby: Downtown San Antonio missing";
(my $sami = $sa->{mi}) =~ s/\.\d+$//;
$src =~ m{Downtown San Antonio is $sami miles north, about $sa->{min} minutes} or die "Location lede does not match SITE.nearby (San Antonio $sami mi / $sa->{min} min)";
my $maxmin = (sort { $b <=> $a } map { $_->{min} } @near)[0];
my $nearhtml = join '', map { my $w = $_->{min} / $maxmin * 100; $w = 6 if $w < 6;
  '<li><b>' . h($_->{name}) . qq{</b><span class="t num">~$_->{min} min</span><span class="addr">} . h($_->{addr}) . " · $_->{mi} mi</span>"
  . sprintf('<span class="bar"><i style="width:%d%%"></i></span></li>', $w + 0.5) } @near;

my $faqhtml = join '', map { sprintf '<details%s><summary>%s</summary><p>%s</p></details>',
  ($_ ? '' : ' open'), h($faq[$_][0]), h($faq[$_][1]) } 0 .. $#faq;
my $faqld = '<script type="application/ld+json">{"@context":"https://schema.org","@type":"FAQPage","mainEntity":['
  . join(',', map { sprintf '{"@type":"Question","name":"%s","acceptedAnswer":{"@type":"Answer","text":"%s"}}', j($_->[0]), j($_->[1]) } @faq)
  . "]}</script>\n";

# --- landing pages: pages/<slug>.html -> dist/<slug>/index.html ------------------
# Each file starts with <!-- key: value --> lines (title, description, crumb, status).
# status: draft  -> built only to preview/ (gitignored) until the owner approves it by email
# status: live   -> built to dist/ and listed in the sitemap and the footer
my @pages;
if (opendir my $pd, 'pages') {
  for my $f (sort grep { /\.html$/ } readdir $pd) {
    open my $p, '<:raw', "pages/$f" or die "pages/$f: $!";
    my $txt = do { local $/; <$p> }; close $p;
    my %m; $m{lc $1} = $2 while $txt =~ s{\A\s*<!--\s*(\w+):\s*(.*?)\s*-->\s*}{}s;
    $m{$_} or die "pages/$f: missing <!-- $_: -->" for qw(title description crumb status);
    $m{status} =~ /^(draft|live)$/ or die "pages/$f: status must be draft or live";
    (my $slug = $f) =~ s/\.html$//;
    push @pages, { %m, slug => $slug, body => $txt };
  }
  closedir $pd;
}
my @live = grep { $_->{status} eq 'live' } @pages;

# --- blog: blog/<slug>.html -> dist/blog/<slug>/index.html, plus dist/blog/index.html ----------
# Same <!-- key: value --> header as pages, plus date: YYYY-MM-DD. Newest first.
my @posts;
if (opendir my $bd, 'blog') {
  for my $f (sort grep { /\.html$/ } readdir $bd) {
    open my $p, '<:raw', "blog/$f" or die "blog/$f: $!";
    my $txt = do { local $/; <$p> }; close $p;
    my %m; $m{lc $1} = $2 while $txt =~ s{\A\s*<!--\s*(\w+):\s*(.*?)\s*-->\s*}{}s;
    $m{$_} or die "blog/$f: missing <!-- $_: -->" for qw(title description crumb status date);
    $m{status} =~ /^(draft|live)$/ or die "blog/$f: status must be draft or live";
    $m{date} =~ /^\d{4}-\d\d-\d\d$/ or die "blog/$f: date must be YYYY-MM-DD";
    (my $slug = $f) =~ s/\.html$//;
    push @posts, { %m, slug => "blog/$slug", body => $txt, parent => ['Blog', 'blog/'] };
  }
  closedir $bd;
}
@posts = sort { $b->{date} cmp $a->{date} } @posts;
my @liveposts = grep { $_->{status} eq 'live' } @posts;
sub nicedate { my @m = qw(January February March April May June July August September October November December);
  my ($y, $mo, $d) = split /-/, shift; "$m[$mo-1] " . ($d+0) . ", $y" }

my ($STYLE) = $head =~ m{(<style>.*</style>)}s;
my $FONTS = join "\n", $head =~ m{(<link rel="(?:preconnect|stylesheet)"[^>]*>)}g;
my $LPCSS = <<'CSS';
<style>
.lp{padding-block:clamp(32px,6vw,72px) clamp(56px,8vw,104px)}
.lp .crumbs{font:400 .8rem/1.4 var(--mono);color:var(--ink-3);margin-bottom:22px}.lp .crumbs a{color:inherit}
.lp .kicker{font:500 .78rem/1.2 var(--mono);letter-spacing:.14em;text-transform:uppercase;color:var(--ink-3)}
.lp h1{font-size:clamp(2.1rem,5.4vw,3.6rem);text-transform:uppercase;margin:.35em 0 .45em;max-width:20ch}
.lp h2{font-size:clamp(1.5rem,3vw,2.1rem);margin:2.2em 0 .7em}
.lp p,.lp li{max-width:70ch}.lp p+p{margin-top:.8em}.lp ul,.lp ol{padding-left:1.2em}.lp li+li{margin-top:.4em}
.lp .ctas{display:flex;flex-wrap:wrap;gap:12px;margin-top:1.5em}
.lp table{border-collapse:collapse;width:100%;max-width:760px}
.lp th,.lp td{text-align:left;padding:11px 12px;border-bottom:1px solid var(--rule);vertical-align:top}
.lp th{font:500 .72rem/1 var(--mono);letter-spacing:.12em;text-transform:uppercase;color:var(--ink-3)}
.lp .note{color:var(--ink-2);font-size:.95rem;margin-top:.8em}
.lp-lot{display:grid;grid-template-columns:minmax(0,340px) 1fr;gap:22px;padding:18px;border:1px solid var(--rule);background:var(--paper);border-radius:4px;margin-bottom:16px}
.lp-lot img{width:100%;height:auto;aspect-ratio:3/2;object-fit:cover;border-radius:3px}
.lp-lot h3{margin:0 0 .3em}.lp-lot .dep{font:400 .85rem/1.4 var(--mono);color:var(--ink-2);margin-bottom:.6em}
.lp-lot .feat{display:flex;flex-wrap:wrap;gap:6px;list-style:none;padding:0;margin:.9em 0 1.1em}
.lp-lot .feat li{font:500 .78rem/1 var(--mono);padding:6px 8px;background:var(--sunk);border-radius:3px;margin:0}
.lp details{border-bottom:1px solid var(--rule);padding:12px 0;max-width:760px}.lp summary{font-weight:600;cursor:pointer}.lp details p{margin-top:.5em}
.lp .postlist{list-style:none;padding:0;max-width:760px}.lp .postlist li{padding:16px 0;border-bottom:1px solid var(--rule);margin:0}
.lp .postlist b{font-size:1.25rem}.lp .postlist small{font:400 .8rem/1.4 var(--mono);color:var(--ink-3)}
@media (max-width:720px){.lp-lot{grid-template-columns:1fr}}
</style>
CSS

my $LDBIZ = { '@type' => 'RVPark', name => 'Vaquero RV Park', url => "$SITE_URL/", telephone => '+1-830-480-2590',
  address => { '@type' => 'PostalAddress', streetAddress => '772 Humble Camp Rd', addressLocality => 'Pleasanton',
               addressRegion => 'TX', postalCode => '78064', addressCountry => 'US' },
  hasMap => 'https://www.google.com/maps?cid=8498488223138810579',
  sameAs => ['https://www.facebook.com/profile.php?id=61590798300769'] };

# {{TOKENS}} a page may use; every fact comes from the parsed site data above
sub lotcards {
  my ($want, $base) = @_;
  my @l = grep { $_->{status} eq 'available' && (!$want || $_->{type} eq $want) } @open;
  return qq{<p>Nothing open in this category today. Get on the waitlist: call or text <a href="$TELHREF">$PHONE</a> and you'll hear first.</p>} unless @l;
  join "\n", map {
    my $l = $_; my $tn = h($type{$l->{type}}{name} // $l->{type});
    my $img = $l->{ph} ? "photos/lot$l->{id}-1.jpg" : 'photos/aerial-front.jpg';
    qq{<div class="lp-lot"><img src="$base$img" alt="Lot $l->{id}, $tn at Vaquero RV Park in Pleasanton, TX" width="480" height="320" loading="lazy">}
    . qq{<div><h3>Lot $l->{id} · } . money($l->{rent}) . qq{/mo</h3><p class="dep">$tn · deposit } . money($l->{deposit}) . qq{</p>}
    . '<p>' . h($l->{desc}) . '</p><ul class="feat">' . join('', map { '<li>' . h($_) . '</li>' } @{$l->{features}}) . '</ul>'
    . qq{<a class="btn btn-primary" href="${base}index.html#lots">See every photo</a></div></div>}
  } @l;
}
sub fill {
  my ($t, $base) = @_;
  $t =~ s{\{\{(\w+)(?::([\w-]+))?\}\}}{
    my ($k, $a) = ($1, $2);
    $k eq 'PHONE'     ? qq{<a href="$TELHREF">$PHONE</a>} :
    $k eq 'TEL'       ? $TELHREF :
    $k eq 'UTILITIES' ? h($UTIL) :   # SITE.utilities: included in the rent on every rental
    $k eq 'BASE'      ? $base :
    $k eq 'RENT'      ? (defined $type{$a // ''}{rent} ? money($type{$a}{rent}) : die "{{RENT:$a}}: no rent for that type\n") :
    $k eq 'OPEN_LOTS' ? lotcards($a, $base) :
    $k eq 'OPEN_COUNT'? scalar(grep { $_->{status} eq 'available' && (!$a || $_->{type} eq $a) } @open) :
    $k eq 'FAQ'       ? qq{<h2>Straight answers</h2>\n$faqhtml} :
    $k eq 'NEARBY_CHECKED' ? h($CHECKED) :
    # {{DRIVE:Floresville}} / {{DRIVE:San_Antonio}} -> "about 30 minutes (24.9 miles via TX-97 E)", from SITE.nearby only
    ($k eq 'DRIVE' || $k eq 'DRIVE_MIN') ? do { my $q = $a // ''; $q =~ s/_/ /g;
                               my ($n) = grep { $_->{name} =~ /(?<![\w-])\Q$q\E(?![\w-])/i } @near;
                               $n or die "{{$k:$a}}: no such place in SITE.nearby\n";
                               $k eq 'DRIVE_MIN' ? $n->{min}
                                 : "about $n->{min} minutes ($n->{mi} miles" . ($n->{addr} =~ /^via /i ? ' ' : ', ') . h($n->{addr}) . ')' } :
    $k eq 'NEARBY_TOWNS'   ? join("\n", map { '<h3>' . h($_->{name}) . " · ~$_->{min} min · $_->{mi} mi</h3><p>" . h($_->{town})
                               . ' Drive ' . h($_->{addr}) . '.</p>' } grep { $_->{town} } @near) :
    $k eq 'NEARBY_TABLE'   ? '<table><thead><tr><th>Place</th><th>Route</th><th>Distance</th><th>Drive</th></tr></thead><tbody>'
                             . join('', map { '<tr><td>' . h($_->{name}) . '</td><td>' . h($_->{addr}) . "</td><td>$_->{mi} mi</td><td><b>~$_->{min} min</b></td></tr>" } @near)
                             . '</tbody></table>' :
    $k eq 'RATES'     ? '<table><thead><tr><th>Rental</th><th>What it is</th><th>Rent</th></tr></thead><tbody>'
                        . join('', map { my $r = $type{$_}; '<tr><td>' . h($r->{name}) . '</td><td>' . h($r->{desc}) . '</td><td><b>'
                          . (defined $r->{rent} ? ($r->{from} ? 'from ' : '') . money($r->{rent}) . '/mo' : 'Ask us') . '</b></td></tr>' } @types)
                        . '</tbody></table>' :
    die "unknown token {{$k}}\n";
  }ge;
  $t;
}
sub render_page {
  my ($pg, $base, $canon) = @_;
  my $body = fill($pg->{body}, $base);
  my ($title, $desc) = map { fill($pg->{$_}, $base) } qw(title description);  # titles may use {{RENT:...}}
  my $guides = join '', map { qq{<li><a href="$base$_->{slug}/">} . h($_->{crumb}) . '</a></li>' } @live;
  # built as data and encoded, so the JSON is always valid (hand-quoted braces broke it once)
  my @trail = ({ name => 'Vaquero RV Park', item => "$SITE_URL/" });
  push @trail, { name => $pg->{parent}[0], item => "$SITE_URL/$pg->{parent}[1]" } if $pg->{parent};
  push @trail, { name => $pg->{crumb}, item => $canon };
  my @graph = ($LDBIZ, { '@type' => 'BreadcrumbList', itemListElement => [
    map { { '@type' => 'ListItem', position => $_ + 1, %{$trail[$_]} } } 0 .. $#trail ] });
  push @graph, { '@type' => 'BlogPosting', headline => $pg->{crumb}, description => $desc, datePublished => $pg->{date},
    url => $canon, image => "$SITE_URL/photos/aerial-hero.jpg",
    author => { '@type' => 'Organization', name => 'Vaquero RV Park' }, publisher => { '@type' => 'Organization', name => 'Vaquero RV Park' } }
    if $pg->{date};
  my $ld = '<script type="application/ld+json">' . JSON::PP->new->canonical->encode({
    '@context' => 'https://schema.org', '@graph' => \@graph }) . '</script>';
  my $crumbs = qq{<a href="${base}index.html">Vaquero RV Park</a> › }
    . ($pg->{parent} ? qq{<a href="$base$pg->{parent}[1]">} . h($pg->{parent}[0]) . '</a> › ' : '') . h($pg->{crumb});
  my $dateline = $pg->{date} ? '<p class="kicker">' . nicedate($pg->{date}) . ' · Vaquero RV Park</p>'
               : $pg->{updated} ? '<p class="kicker">Updated ' . nicedate($pg->{updated}) . '</p>' : '';
  my $faq = $pg->{body} =~ /\{\{FAQ\}\}/ ? $faqld : '';
  # <!-- faqpage: yes -->: FAQ structured data from every question on the page itself (after tokens are filled)
  if (($pg->{faqpage} // '') eq 'yes') {
    my @qa;
    while ($body =~ m{<details[^>]*>\s*<summary>(.*?)</summary>\s*(.*?)</details>}sg) {
      my ($q, $a) = ($1, $2);
      for ($q, $a) { s{<[^>]+>}{}g; s/&amp;/&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/\s+/ /g; s/^ | $//g }
      push @qa, { '@type' => 'Question', name => $q, acceptedAnswer => { '@type' => 'Answer', text => $a } };
    }
    @qa or die "$pg->{slug}: faqpage: yes but no <details> questions found\n";
    $faq = '<script type="application/ld+json">' . JSON::PP->new->canonical->encode({
      '@context' => 'https://schema.org', '@type' => 'FAQPage', mainEntity => \@qa }) . "</script>\n";
  }
  return <<"HTML";
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>$title</title>
<meta name="description" content="@{[h($desc)]}">
<link rel="canonical" href="$canon">
<meta name="theme-color" content="#2B1A10">
<link rel="icon" href="${base}photos/app-icon.png">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Vaquero RV Park">
<meta property="og:title" content="$title">
<meta property="og:description" content="@{[h($desc)]}">
<meta property="og:url" content="$canon">
<meta property="og:image" content="$SITE_URL/photos/aerial-hero.jpg">
$FONTS
$STYLE
$LPCSS$ld
$faq</head>
<body>
<header class="nav">
  <div class="wrap nav-in">
    <a class="brand" href="${base}index.html" aria-label="Vaquero RV Park home">
      <img class="plate" src="${base}photos/logo-horizontal.webp" alt="Vaquero RV Park, Pleasanton, TX" width="420" height="85">
    </a>
    <nav class="nav-links"><a href="${base}index.html#lots">Lots</a><a href="${base}index.html#rates">Rates</a><a href="${base}index.html#location">Location</a><a href="${base}index.html#faq">FAQ</a><a href="${base}nearby-towns/">Nearby towns</a><a href="${base}blog/">Blog</a></nav>
    <a class="call" href="$TELHREF">$PHONE</a>
    <a class="btn btn-primary" href="${base}index.html#contact">Inquire</a>
  </div>
</header>
<main>
<article class="lp"><div class="wrap">
<p class="crumbs">$crumbs</p>
$dateline$body
<p class="ctas"><a class="btn btn-primary" href="${base}index.html#contact">Ask about a lot</a> <a class="btn btn-line" href="$TELHREF">Call or text $PHONE</a></p>
</div></article>
</main>
<footer>
  <div class="wrap">
    <div class="foot">
      <div><p style="color:var(--ink-2);max-width:36ch">Vaquero RV Park · 772 Humble Camp Rd, Pleasanton, TX 78064. Long-term RV lots, park-owned RVs and tiny homes, by the month.</p></div>
      <div><h4>Reach us</h4><ul><li><a href="$TELHREF">$PHONE</a></li><li><a href="${base}index.html#contact">Send an inquiry</a></li></ul></div>
      <div><h4>Guides</h4><ul>$guides</ul></div>
    </div>
    <p class="foot small">© 2026 Vaquero RV Park · SKAT-OS Holdings LLC</p>
  </div>
</footer>
<nav class="mbar" aria-label="Quick contact"><a href="$TELHREF">Call</a><a href="@{[$TELHREF =~ s/^tel:/sms:/r]}">Text</a><a class="go" href="${base}index.html#contact">Inquire</a></nav>
</body>
</html>
HTML
}

# --- dist: the deployable site ------------------------------------------------
make_path('dist/photos');
my $prod = $head;
$prod =~ s{<title>.*?</title>}{<title>$TITLE</title>}s;
$prod =~ s{<meta name="description" content=".*?">}{<meta name="description" content="$DESC">}s;
my $pbody = $body;
# the FAQ is in the HTML itself, so search engines read it without running the script
$pbody =~ s{<div id="faqlist"></div>}{<div id="faqlist">$faqhtml</div>} or die "#faqlist placeholder not found";
# open lots in the HTML too (same markup the script draws with its default "Available" filter), so
# crawlers that don't run JavaScript (Bing, AI search) still see them; the script redraws on load
my $homecards = join '', map {
  my $l = $_; my $tn = h($type{$l->{type}}{name} // $l->{type});
  my $img = $l->{ph} ? "photos/lot$l->{id}-1.jpg" : 'photos/aerial-front.jpg';
  my $no = $l->{id} =~ /^\d$/ ? "0$l->{id}" : $l->{id};
  qq{<button class="lot is-available" type="button" data-lot="$l->{id}" aria-label="Lot $l->{id}, Available, $tn">}
  . qq{<div class="ph"><img loading="lazy" src="$img" alt="Lot $l->{id}, $tn at Vaquero RV Park in Pleasanton, TX" style="object-position:50% 50%"><span class="badge available">Available</span></div>}
  . qq{<div class="body"><div class="row"><span class="no num"><small>LOT</small>$no</span><span class="rent num">} . money($l->{rent}) . qq{<small>/mo</small></span></div>}
  . qq{<span class="type">$tn</span><span class="dep num">Deposit } . money($l->{deposit}) . qq{</span></div></button>}
} grep { $_->{status} eq 'available' } @open;
$pbody =~ s{<div class="lots" id="lotgrid"></div>}{<div class="lots" id="lotgrid">$homecards</div>} or die "#lotgrid placeholder not found";
# priceRange from the lowest listed rent, so it follows the rent roll like every other fact
my ($minrent) = sort { $a <=> $b } grep { defined } map { $type{$_}{rent} } @types;
$prod =~ s{"petsAllowed":true,}{"priceRange":"From @{[money($minrent)]}/month","petsAllowed":true,} or die "home JSON-LD petsAllowed not found";
if (@live) {
  my $g = join '', map { qq{<li><a href="/$_->{slug}/">} . h($_->{crumb}) . '</a></li>' } @live;
  $pbody =~ s{(<div><h4>Park</h4>.*?</div>)}{$1\n      <div><h4>Guides</h4><ul>$g</ul></div>}s or die "footer Park column not found";
  $prod .= "\n<style>\@media (min-width:761px){.foot{grid-template-columns:1.4fr 1fr 1fr 1fr}}</style>";
}
# drive times in the HTML (same markup the script draws), so readers without JavaScript see the same list
$pbody =~ s{<ul class="near" id="near"></ul>}{<ul class="near" id="near">$nearhtml</ul>} or die "#near placeholder not found";
$pbody =~ s{<span id="nearchecked">[^<]*</span>}{<span id="nearchecked">@{[h($CHECKED)]}</span>} or die "#nearchecked not found";
# latest blog posts in the "Life around Pleasanton" section (static, no script needed)
my $bl = join '', map { qq{<li><a href="/$_->{slug}/">} . h($_->{crumb}) . '</a><small>' . nicedate($_->{date}) . '</small></li>' }
  @liveposts[0 .. ($#liveposts < 2 ? $#liveposts : 2)];
$pbody =~ s{<ul class="bloglist" id="bloglist"></ul>}{<ul class="bloglist" id="bloglist">$bl</ul>} or die "#bloglist placeholder not found";
open my $out, '>:raw', 'dist/index.html' or die $!;
print $out qq{<!doctype html>\n<html lang="en">\n<head>\n$meta$prod\n$faqld</head>\n<body>\n$pbody\n</body>\n</html>\n};
close $out;

for my $pg (@live) {
  make_path("dist/$pg->{slug}");
  open my $o, '>:raw', "dist/$pg->{slug}/index.html" or die $!;
  # live links point at "/" itself: Cloudflare redirects /index.html to /, and redirects waste crawl
  (my $html = render_page($pg, '/', "$SITE_URL/$pg->{slug}/")) =~ s{href="/index\.html}{href="/}g;
  print $o $html; close $o;
}
# blog: each live post, plus the index that lists them
my $blogindex = { slug => 'blog', crumb => 'Blog',
  title => 'Blog | Vaquero RV Park, Pleasanton, TX',
  description => 'Notes from Vaquero RV Park on RV living, rent and life around Pleasanton and Atascosa County, Texas.',
  body => qq{<p class="kicker">The Vaquero blog</p>\n<h1>Life around Pleasanton</h1>\n<p>Notes from the park on RV living, what it costs, and what there is to do in Pleasanton and Atascosa County.</p>\n}
    . (@liveposts ? '<ul class="postlist">' . join('', map { qq{<li><a href="/$_->{slug}/"><b>} . h($_->{crumb}) . '</b></a><br><small>'
        . nicedate($_->{date}) . '</small><br>' . h($_->{description}) . '</li>' } @liveposts) . '</ul>' : '<p>First post coming soon.</p>') };
for my $pg (@liveposts, $blogindex) {
  make_path("dist/$pg->{slug}");
  open my $o, '>:raw', "dist/$pg->{slug}/index.html" or die $!;
  (my $html = render_page($pg, '/', "$SITE_URL/$pg->{slug}/")) =~ s{href="/index\.html}{href="/}g;
  print $o $html; close $o;
}
# every structured-data block must parse, or Google ignores it: stop the build instead
for my $f ('dist/index.html', map { "dist/$_->{slug}/index.html" } @live, @liveposts, $blogindex) {
  open my $i, '<:raw', $f or die "$f: $!"; my $html = do { local $/; <$i> }; close $i;
  while ($html =~ m{<script type="application/ld\+json">(.*?)</script>}sg) {
    my $json = $1;
    eval { JSON::PP->new->decode($json); 1 } or die "$f: invalid JSON-LD: $@";
  }
}
# previews of every page (drafts included) that open from disk: preview/<slug>.html
make_path('preview');
for my $pg (@pages, @posts) {
  my $html = render_page($pg, '../dist/', "$SITE_URL/$pg->{slug}/");
  $html =~ s{\.\./dist/([\w-]+)/"}{../preview/$1.html"}g;
  (my $pf = $pg->{slug}) =~ s{/}{-}g;
  open my $o, '>:raw', "preview/$pf.html" or die $!; print $o $html; close $o;
}

opendir my $dh, 'photos' or die $!;
my @photos = grep { /\.(jpg|webp|png)$/i } readdir $dh; closedir $dh;
copy("photos/$_", "dist/photos/$_") or die "copy $_: $!" for @photos;

open my $r, '>:raw', 'dist/robots.txt' or die $!;
print $r "User-agent: *\nAllow: /\n\nSitemap: $SITE_URL/sitemap.xml\n";
close $r;

my ($day, $mon, $yr) = (localtime)[3,4,5];
my $today = sprintf('%04d-%02d-%02d', $yr+1900, $mon+1, $day);

# llms.txt (llmstxt.org): plain-text facts for AI assistants, built from the same SITE data as the pages
{
  my @am;
  push @am, { name => $1, status => $2, desc => $3 }
    while $src =~ m{\{ name: "([^"]+)", status: "(live|soon)", desc: "([^"]+)", icon: "\w+" \}}g;
  @am or die "SITE.amenities not found";
  my $rates = join '', map { my $r = $type{$_}; "- $r->{name}: "
    . (defined $r->{rent} ? ($r->{from} ? 'from ' : '') . money($r->{rent}) . '/month' : 'ask us') . ". $r->{desc}\n" } @types;
  my @avail = grep { $_->{status} eq 'available' } @open;
  my $openl = @avail ? join('', map { "- Lot $_->{id}: " . money($_->{rent}) . '/month, ' . money($_->{deposit})
    . " deposit. $_->{desc}\n" } @avail) : "- No lots open right now. Call or text to join the waitlist.\n";
  my $faqt = join '', map { "- Q: $_->[0]\n  A: $_->[1]\n" } @faq;
  my $neart = join '', map { "- $_->{name}: about $_->{min} minutes, $_->{mi} miles ($_->{addr})\n" } @near;
  my $pagest = join '', map { (my $d = fill($_->{description}, '/')) =~ s{<[^>]+>}{}g;
    "- [$_->{crumb}]($SITE_URL/$_->{slug}/): $d\n" } @live, @liveposts;
  my $amt = join '', map { "- $_->{name}" . ($_->{status} eq 'soon' ? ' (coming soon)' : '') . ": $_->{desc}\n" } @am;
  open my $l, '>:raw', 'dist/llms.txt' or die $!;
  print $l <<"TXT";
# Vaquero RV Park

> Long-term RV park in Pleasanton, Texas (Atascosa County), about $sa->{min} minutes south of downtown San Antonio. Monthly RV lots from @{[money($type{lot30}{rent})]}/month, plus park-owned RVs and tiny homes for people without a rig. Monthly stays only: no nightly or weekly stays.

- Address: 772 Humble Camp Rd, Pleasanton, TX 78064
- Phone (call or text): $PHONE
- Included in the rent on every rental, bare RV lots too: $UTIL. No separate utility bills.
- Website: $SITE_URL/
- How to rent: send the inquiry form at $SITE_URL/#contact, or call or text. Approved residents pay rent through the resident portal.
- Facts current as of $today. Rent and open lots change; the website is the source of truth.

## Rent by rental type
$rates
## Open now
$openl
## Amenities
$amt
## Drive times from the park (checked on Google Maps, $CHECKED)
$neart
## Frequently asked questions
$faqt
## Pages
- [Home]($SITE_URL/): open lots, rates, amenities, location and the inquiry form
$pagest
## Optional
- [Facebook](https://www.facebook.com/profile.php?id=61590798300769)
TXT
  close $l;
}
open my $s, '>:raw', 'dist/sitemap.xml' or die $!;
print $s qq{<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n}
        . qq{  <url><loc>$SITE_URL/</loc><lastmod>$today</lastmod><changefreq>weekly</changefreq><priority>1.0</priority></url>\n}
        . join('', map { qq{  <url><loc>$SITE_URL/$_->{slug}/</loc><lastmod>$today</lastmod><changefreq>weekly</changefreq><priority>0.8</priority></url>\n} } @live, $blogindex)
        . join('', map { qq{  <url><loc>$SITE_URL/$_->{slug}/</loc><lastmod>$_->{date}</lastmod><changefreq>monthly</changefreq><priority>0.6</priority></url>\n} } @liveposts)
        . qq{</urlset>\n};
close $s;

# --- standalone: one file to email --------------------------------------------
my %mime = (jpg=>'image/jpeg', webp=>'image/webp', png=>'image/png');
my $solo = $src;
$solo =~ s{photos/([\w-]+)\.(jpg|webp|png)}{
  open my $p, '<:raw', "photos/$1.$2" or die "missing $1.$2";
  my $data = do { local $/; <$p> }; close $p;
  "data:$mime{$2};base64," . encode_base64($data, '')
}ge;
$solo =~ s{</style>}{</style>\n</head>\n<body>};
open my $so, '>:raw', 'Vaquero-RV-Park-Website-Prototype.html' or die $!;
print $so qq{<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n}
        . qq{<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">\n}
        . qq{<style>body{margin:0}img{max-width:100%}[hidden]{display:none!important}</style>\n}
        . $solo . qq{\n</body>\n</html>\n};
close $so;

printf "built dist/ (%d photos) and the standalone copy for %s\n", scalar(@photos), $SITE_URL;
