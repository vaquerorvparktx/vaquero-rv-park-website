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

# --- dist: the deployable site ------------------------------------------------
make_path('dist/photos');
my $prod = $head;
$prod =~ s{<title>.*?</title>}{<title>$TITLE</title>}s;
$prod =~ s{<meta name="description" content=".*?">}{<meta name="description" content="$DESC">}s;
open my $out, '>:raw', 'dist/index.html' or die $!;
print $out qq{<!doctype html>\n<html lang="en">\n<head>\n$meta$prod\n</head>\n<body>\n$body\n</body>\n</html>\n};
close $out;

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
