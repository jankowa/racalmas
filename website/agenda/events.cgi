#! /usr/bin/perl -w

use warnings "all";

#no warnings 'redefine';
#use diagnostics;
use strict;
use Data::Dumper;

#use utf8;
use DBI;
use CGI qw(header param Vars);
$CGI::POST_MAX        = 1000;
$CGI::DISABLE_UPLOADS = 1;

use params;
use config;
use log;
use events;
use time;

#binmode STDOUT, ":utf8";
binmode STDOUT, ":encoding(UTF-8)";

my $r = shift;
( my $cgi, my $params, my $error ) = params::get($r);

if ( $0 =~ /events.*?\.cgi$/ ) {

	#my $cgi=new CGI();
	#my %params=$cgi->Vars();
	our $config = config::get('config/config.cgi');

	$params->{recordings} = 1 if $params->{template} =~ /events_playout/;
	my $request = {
		url    => $ENV{QUERY_STRING},
		params => {
			original => $params,
			checked  => events::check_params( $config, $params ),
		},
	};

	#events::init($request);
	log::init($request);

	my $output = '';
	events::get_cached_or_render( $output, $config, $request );
	print $output. "\n";
}

1;
