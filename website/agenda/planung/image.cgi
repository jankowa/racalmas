#! /usr/bin/perl -w

use warnings "all";
use strict;
use Data::Dumper;

use File::stat;
use Time::localtime;
use CGI qw(header param Vars escapeHTML uploadInfo cgi_error);
use URI::Escape;

use time;
use images;
use params;
use config;
use log;
use template;
use db;
use auth;
use uac;
use project;
use time;
use markup;
use studios;
use series;
use localization;

binmode STDOUT, ":utf8";

my $r = shift;
( my $cgi, my $params, my $error ) = params::get($r);
$CGI::POST_MAX = 1024 * 10;

my $config = config::get('../config/config.cgi');
my $debug  = $config->{system}->{debug};
my ( $user, $expires ) = auth::get_user( $cgi, $config );
return if ( ( !defined $user ) || ( $user eq '' ) );

my $user_presets = uac::get_user_presets(
	$config,
	{
		user       => $user,
		project_id => $params->{project_id},
		studio_id  => $params->{studio_id}
	}
);
$params->{default_studio_id} = $user_presets->{studio_id};
$params->{studio_id}         = $params->{default_studio_id}
  if ( ( !( defined $params->{action} ) ) || ( $params->{action} eq '' ) || ( $params->{action} eq 'login' ) );
$params->{project_id} = $user_presets->{project_id}
  if ( ( !( defined $params->{action} ) ) || ( $params->{action} eq '' ) || ( $params->{action} eq 'login' ) );

my $request = {
	url => $ENV{QUERY_STRING} || '',
	params => {
		original => $params,
		checked  => check_params($params),
	}
};
$request = uac::prepare_request( $request, $user_presets );
log::init($request);
$params = $request->{params}->{checked};

#show header
my $headerParams = uac::set_template_permissions( $request->{permissions}, $params );
$headerParams->{loc} = localization::get( $config, { user => $user, file => 'menu' } );
template::process( 'print', template::check('ajax_header.html'), $headerParams );
return unless defined uac::check( $config, $params, $user_presets );

#my $base_dir	    = $config->{locations}->{base_dir};
my $local_media_dir = $config->{locations}->{local_media_dir};
my $local_media_url = $config->{locations}->{local_media_url};

#my $local_base_url	= $config->{locations}->{local_base_url};

log::error( $config, 'cannot locate media dir' . $local_media_dir ) unless ( -e $local_media_dir );

#continue on error
uac::permissions_denied('reading from local media dir') unless ( -r $local_media_dir );
uac::permissions_denied('writing to local media dir')   unless ( -w $local_media_dir );

if ( $params->{delete_image} ne '' ) {
	delete_image( $config, $request, $user, $local_media_dir );
	return;
} elsif ( $params->{save_image} ne '' ) {
	save_image( $config, $request, $user );
	return;
}
show_image( $config, $request, $user, $local_media_url );

sub show_image {
	my $config          = shift;
	my $request         = shift;
	my $user            = shift;
	my $local_media_url = shift;

	my $params      = $request->{params}->{checked};
	my $permissions = $request->{permissions};

	unless ( defined $params->{project_id} ) {
		uac::print_error("missing project id");
		return undef;
	}
	unless ( defined $params->{studio_id} ) {
		uac::print_error("missing studio id");
		return undef;
	}

	if ( $permissions->{read_image} ne '1' ) {
		uac::permissions_denied("read image");
		return 0;
	}

	$config->{access}->{write} = 0;
	my $dbh = db::connect( $config, undef );

	my $selectedFilename = $params->{filename} || '';
	my $filenames        = {};
	my $results          = [];

	# add images from series
	if ( defined $params->{series_id} ) {
		my $seriesImages = series::get_images( $config, $params );

		for my $image (@$seriesImages) {
			my $filename = $image->{filename};
			unless ( defined $filenames->{$filename} ) {

				#print STDERR "add1 $filename\n";
				push @$results, $image;
				$filenames->{$filename} = $image;
			}
		}
	}

	#load images matching by search
	if ( defined $params->{search} ) {

		#remove filename from search
		delete $params->{filename};
		delete $params->{series_id};
		my $searchImages = images::get( $config, $params );

		for my $image (@$searchImages) {
			my $filename = $image->{filename};
			unless ( defined $filenames->{$filename} ) {

				#print STDERR "add2 $filename\n";
				push @$results, $image;
				$filenames->{$filename} = $image;
			}
		}
	}

	#load selected image, if not already loaded
	if ( $selectedFilename ne '' ) {
		my $search = $params->{search} || '';

		# use selected image if already loaded
		my $selectedImage = undef;
		if ( defined $filenames->{$selectedFilename} ) {
			$selectedImage = $filenames->{$selectedFilename};
		} else {

			#now add filename and remove search
			$params->{filename} = $selectedFilename;
			delete $params->{search};

			#put selected image to the top
			my $imagesByNames = images::get( $config, $params );
			$selectedImage = $imagesByNames->[0] if ( scalar(@$imagesByNames) > 0 );
		}

		my $finalResults = [];

		# put selected image first
		$selectedFilename = 'not-found';
		if ( defined $selectedImage ) {
			push @$finalResults, $selectedImage;
			$selectedFilename = $selectedImage->{filename};
		}

		# then other images
		for my $image (@$results) {
			push @$finalResults, $image if $image->{filename} ne $selectedFilename;
		}
		$results = $finalResults;

		#add search again
		$params->{search} = $search;
	}

	if ( $params->{template} =~ /edit/ ) {
		$results = [ $results->[0] ] || undef;
	}
	if ( defined $results ) {
		$results = modify_results( $results, $permissions, $user, $local_media_url );
	}

	my $search = $params->{search} || '';
	$search =~ s/\%+/ /g;
	my $template_params = {
		'search'     => $search,
		'images'     => $results,
		'count'      => @$results . '',
		'projects'   => project::get_with_dates($config),
		'project_id' => $params->{project_id},
		'studio_id'  => $params->{studio_id},
		'filename'   => $params->{filename}
	};

	#    print STDERR
	$template_params->{loc} = localization::get( $config, { user => $params->{presets}->{user}, file => 'image' } );
	$template_params = uac::set_template_permissions( $permissions, $template_params );

	#set global values for update and delete, per image values are evaluated later
	$template_params->{allow}->{update_image} =
	  $template_params->{allow}->{update_image_own} || $template_params->{allow}->{seriesupdate_image_others};
	$template_params->{allow}->{delete_image} =
	  $template_params->{allow}->{delete_image_own} || $template_params->{allow}->{delete_image_others};
	template::process( 'print', $params->{template}, $template_params );
}

sub print_js_error {
	my $message = shift;
	print qq{<!--
    ERROR: $message
    -->
    };
	print STDERR $message . "\n";
}

sub save_image {
	my $config  = shift;
	my $request = shift;
	my $user    = shift;

	my $params      = $request->{params}->{checked};
	my $permissions = $request->{permissions};

	unless ( check_permission( $config, $user, $permissions, 'update_image', $params->{save_image} ) eq '1' ) {
		print_js_error("missing permission to update image");
		return 0;
	}

	if ( ( $params->{update_name} eq '' ) && ( $params->{update_description} eq '' ) ) {
		print_js_error("empty name or empty description!");
		return 0;
	}

	my $image = {};
	$image->{filename}    = $params->{save_image};
	$image->{name}        = $params->{update_name} if ( $params->{update_name} ne '' );
	$image->{description} = $params->{update_description} if ( $params->{update_description} ne '' );
	$image->{project_id}  = $params->{project_id};
	$image->{studio_id}   = $params->{studio_id};
	$image->{modified_by} = $user;

	$image->{name} = 'new' if ( $image->{name} eq '' );

	$config->{access}->{write} = 1;
	my $dbh = db::connect($config);

	#print STDERR "going to save\n";
	my $entries = images::get(
		$config,
		{
			filename   => $image->{filename},
			project_id => $image->{project_id},
			studio_id  => $image->{studio_id}
		}
	);

	#print STDERR Dumper($entries);
	if ( scalar @$entries > 1 ) {
		print_js_error('more than one matching result found');
		return 0;
	}
	if ( scalar @$entries == 0 ) {
		print_js_error('image not found in database (for this studio)');
		return 0;
	}
	my $entry = $entries->[0];
	if ( defined $entry ) {
		images::update( $dbh, $image );
	} else {
		$image->{created_by} = $user;
		images::insert( $dbh, $image );
	}
}

sub delete_image {
	my $config          = shift;
	my $request         = shift;
	my $user            = shift;
	my $local_media_dir = shift;

	my $params      = $request->{params}->{checked};
	my $permissions = $request->{permissions};

	unless ( check_permission( $config, $user, $permissions, 'delete_image', $params->{delete_image} ) eq '1' ) {
		uac::permissions_denied('delete image');
		return 0;
	}

	#print $cgi->header();
	#print "Content-type:text/html; charset=UTF-8;\n\n";

	$config->{access}->{write} = 1;
	my $dbh   = db::connect($config);
	my $image = {
		project_id => $params->{project_id},
		studio_id  => $params->{studio_id},
		filename   => $params->{delete_image},
	};
	my $result = images::delete( $dbh, $image );
	print STDERR "delete result=" . Dumper($result);

	return;
	my $action_result = '';
	my $errors        = '';
	$result = images::delete_files( $config, $local_media_dir, $params->{delete_image}, $action_result, $errors );

	#use Data::Dumper;print STDERR "delete\n".Dumper($params);
	print "deleted<br />$action_result<br />$errors\n";
}

sub check_permission {
	my $config      = shift;
	my $user        = shift;
	my $permissions = shift;
	my $permission  = shift;
	my $filename    = shift;

	return 0 unless defined $user;
	return 0 if ( $user eq '' );

	if ( $permissions->{ $permission . '_others' } eq '1' ) {
		print STDERR "$user has update_image_others\n";
		return 1;
	} elsif ( $permissions->{ $permission . '_own' } eq '1' ) {
		print STDERR "$user has update_image_own\n";

		#check if image was created by user
		my $results = images::get(
			$config,
			{
				filename   => $filename,
				created_by => $user
			}
		);
		return 1 if ( @$results == 1 );
		return 0;
	}
	return 0;
}

sub modify_results {
	my $results         = shift;
	my $permissions     = shift;
	my $user            = shift;
	my $local_media_url = shift;

	for my $result (@$results) {
		unless ( defined $result->{filename} ) {
			$result = undef;
			next;
		}
		$result->{image_url} = $local_media_url . '/images/' . $result->{filename};
		$result->{thumb_url} = $local_media_url . '/thumbs/' . $result->{filename};
		$result->{icon_url}  = $local_media_url . '/icons/' . $result->{filename};

		#reduce
		for my $permission ( 'update_image', 'delete_image' ) {
			if ( ( defined $permissions->{ $permission . '_others' } ) && ( $permissions->{ $permission . '_others' } eq '1' ) ) {
				$result->{$permission} = 1;
			} elsif ( ( defined $permissions->{ $permission . '_own' } ) && ( $permissions->{ $permission . '_own' } eq '1' ) ) {
				next if ( $user eq '' );
				$result->{$permission} = 1 if ( $user eq $result->{created_by} );
			}
		}
	}
	return $results;
}

sub check_params {
	my $params = shift;

	my $checked = { template => template::check( $params->{template}, 'image.html' ) };

	#numeric values
	$checked->{limit} = 100;
	for my $param ( 'project_id', 'studio_id', 'series_id', 'default_studio_id', 'limit' ) {
		if ( ( defined $params->{$param} ) && ( $params->{$param} =~ /^\d+$/ ) ) {
			$checked->{$param} = $params->{$param};
		}
	}
	if ( defined $checked->{studio_id} ) {
		$checked->{default_studio_id} = $checked->{studio_id};
	} else {
		$checked->{studio_id} = -1;
	}

	$checked->{limit} = 100 unless defined $checked->{limit};
	$checked->{limit} = 100 if ( $checked->{limit} > 100 );

	#string
	$checked->{search} = '';
	if ( ( defined $params->{search} ) && ( $params->{search} =~ /^\s*(.+?)\s*$/ ) ) {
		$checked->{search} = $1;
	}

	for my $attr ( 'update_name', 'update_description' ) {
		$checked->{$attr} = '';
		if ( ( defined $params->{$attr} ) && ( $params->{$attr} =~ /^\s*(.+?)\s*$/ ) ) {
			$checked->{$attr} = $params->{$attr};
		}
	}

	#Words
	$checked->{delete_image} = '';
	$checked->{save_image}   = '';
	for my $attr ( 'save_image', 'delete_image', 'show', 'filename' ) {
		$checked->{$attr} = '';
		if ( ( defined $params->{$attr} ) && ( $params->{$attr} =~ /(\S+)/ ) ) {
			$checked->{$attr} = $params->{$attr};
		}
	}

	#map show to filename, but overwrite if filename given
	if ( $checked->{show} ne '' ) {
		$checked->{filename} = $checked->{show};
		delete $checked->{show};
		$checked->{limit} = 1;
	} elsif ( $checked->{filename} ne '' ) {
		delete $checked->{show};
	}

	$checked->{from} = time::check_date( $params->{from} );
	$checked->{till} = time::check_date( $params->{till} );

	return $checked;
}

