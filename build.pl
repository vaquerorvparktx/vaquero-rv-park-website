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
use strict; use warnings; use MIME::Base64; use File::Path qw(make_path); use File::Copy qw(copy);

my $SITE_URL = $ENV{SITE_URL} || 'https://vaquerorvpark.com';
$SITE_URL =~ s{/$}{};
my $TITLE = 'Vaquero RV Park | Monthly RV Lots &amp; Park-Owned RVs in Pleasanton, TX';
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
@media (max-width:720px){.lp-lot{grid-template-columns:1fr}}
</style>
CSS

my $LDBIZ = qq{"\@type":"RVPark","name":"Vaquero RV Park","url":"$SITE_URL/","telephone":"+1-830-480-2590"};

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
  $t =~ s{\{\{(\w+)(?::(\w+))?\}\}}{
    my ($k, $a) = ($1, $2);
    $k eq 'PHONE'     ? qq{<a href="$TELHREF">$PHONE</a>} :
    $k eq 'TEL'       ? $TELHREF :
    $k eq 'BASE'      ? $base :
    $k eq 'RENT'      ? (defined $type{$a // ''}{rent} ? money($type{$a}{rent}) : die "{{RENT:$a}}: no rent for that type\n") :
    $k eq 'OPEN_LOTS' ? lotcards($a, $base) :
    $k eq 'OPEN_COUNT'? scalar(grep { $_->{status} eq 'available' && (!$a || $_->{type} eq $a) } @open) :
    $k eq 'FAQ'       ? qq{<h2>Straight answers</h2>\n$faqhtml} :
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
  my $ld = qq{<script type="application/ld+json">{"\@context":"https://schema.org","\@graph":[{$LDBIZ},}
         . qq{{"\@type":"BreadcrumbList","itemListElement":[{"\@type":"ListItem","position":1,"name":"Vaquero RV Park","item":"$SITE_URL/"},}
         . qq{{"\@type":"ListItem","position":2,"name":"} . j($pg->{crumb}) . qq{","item":"$canon"}]}]}</script>};
  my $faq = $pg->{body} =~ /\{\{FAQ\}\}/ ? $faqld : '';
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
    <nav class="nav-links"><a href="${base}index.html#lots">Lots</a><a href="${base}index.html#rates">Rates</a><a href="${base}index.html#location">Location</a><a href="${base}index.html#faq">FAQ</a></nav>
    <a class="call" href="$TELHREF">$PHONE</a>
    <a class="btn btn-primary" href="${base}index.html#contact">Inquire</a>
  </div>
</header>
<main>
<article class="lp"><div class="wrap">
<p class="crumbs"><a href="${base}index.html">Vaquero RV Park</a> › @{[h($pg->{crumb})]}</p>
$body
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
if (@live) {
  my $g = join '', map { qq{<li><a href="/$_->{slug}/">} . h($_->{crumb}) . '</a></li>' } @live;
  $pbody =~ s{(<div><h4>Park</h4>.*?</div>)}{$1\n      <div><h4>Guides</h4><ul>$g</ul></div>}s or die "footer Park column not found";
  $prod .= "\n<style>\@media (min-width:761px){.foot{grid-template-columns:1.4fr 1fr 1fr 1fr}}</style>";
}
open my $out, '>:raw', 'dist/index.html' or die $!;
print $out qq{<!doctype html>\n<html lang="en">\n<head>\n$meta$prod\n$faqld</head>\n<body>\n$pbody\n</body>\n</html>\n};
close $out;

for my $pg (@live) {
  make_path("dist/$pg->{slug}");
  open my $o, '>:raw', "dist/$pg->{slug}/index.html" or die $!;
  print $o render_page($pg, '/', "$SITE_URL/$pg->{slug}/"); close $o;
}
# previews of every page (drafts included) that open from disk: preview/<slug>.html
make_path('preview');
for my $pg (@pages) {
  my $html = render_page($pg, '../dist/', "$SITE_URL/$pg->{slug}/");
  $html =~ s{\.\./dist/([\w-]+)/"}{../preview/$1.html"}g;
  open my $o, '>:raw', "preview/$pg->{slug}.html" or die $!; print $o $html; close $o;
}

opendir my $dh, 'photos' or die $!;
my @photos = grep { /\.(jpg|webp|png)$/i } readdir $dh; closedir $dh;
copy("photos/$_", "dist/photos/$_") or die "copy $_: $!" for @photos;

open my $r, '>:raw', 'dist/robots.txt' or die $!;
print $r "User-agent: *\nAllow: /\n\nSitemap: $SITE_URL/sitemap.xml\n";
close $r;

my ($day, $mon, $yr) = (localtime)[3,4,5];
my $today = sprintf('%04d-%02d-%02d', $yr+1900, $mon+1, $day);
open my $s, '>:raw', 'dist/sitemap.xml' or die $!;
print $s qq{<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n}
        . qq{  <url><loc>$SITE_URL/</loc><lastmod>$today</lastmod><changefreq>weekly</changefreq><priority>1.0</priority></url>\n}
        . join('', map { qq{  <url><loc>$SITE_URL/$_->{slug}/</loc><lastmod>$today</lastmod><changefreq>weekly</changefreq><priority>0.8</priority></url>\n} } @live)
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
