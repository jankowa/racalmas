#! /usr/bin/perl -w 

use warnings "all";
use strict;
use Data::Dumper;

use config;
use params;
use log;
use template;
use auth;
use roles;
use uac;
use studios;
use series;
use localization;

my $r = shift;
( my $cgi, my $params, my $error ) = params::get($r);

my $config = config::get('../config/config.cgi');
my $debug  = $config->{system}->{debug};

my ( $user, $expires ) = auth::get_user( $cgi, $config );
return if ( $user eq '' );

my $permissions  = roles::get_user_permissions();
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
	},
};
$request = uac::prepare_request( $request, $user_presets );
log::init($request);

$params = $request->{params}->{checked};

#process header
my $headerParams = uac::set_template_permissions( $request->{permissions}, $params );
$headerParams->{loc} = localization::get( $config, { user => $user, file => 'menu' } );
template::process( 'print', template::check('default.html'), $headerParams );
return unless uac::check( $config, $params, $user_presets ) == 1;

print q{
	<link rel="stylesheet" href="css/studios.css" type="text/css" /> 
	<script src="js/studios.js"  type="text/javascript"></script>
};

if ( defined $params->{action} ) {
	save_studio( $config, $request ) if ( $params->{action} eq 'save' );
	delete_studio( $config, $request ) if ( $params->{action} eq 'delete' );
}
$config->{access}->{write} = 0;
show_studios( $config, $request );

sub delete_studio {
	my $config  = shift;
	my $request = shift;

	my $permissions = $request->{permissions};
	unless ( $permissions->{update_studio} == 1 ) {
		uac::permissions_denied('update_studio');
		return;
	}

	my $params  = $request->{params}->{checked};
	my $columns = studios::get_columns($config);

	my $entry = {};
	for my $param ( keys %$params ) {
		if ( defined $columns->{$param} ) {
			$entry->{$param} = $params->{$param} || '';
		}
	}

	my $studio_id = $entry->{id} || '';
	if ( $studio_id ne '' ) {
		$config->{access}->{write} = 1;

		project::unassign_studio(
			$config,
			{
				project_id => $params->{project_id},
				studio_id  => $studio_id
			}
		);

		my $studio_assignments = project::get_studio_assignments(
			$config,
			{
				studio_id => $studio_id
			}
		);

		unless ( @$studio_assignments == 0 ) {
			uac::print_info("Studio unassigned from project");
			uac::print_warn("Studio is assigned to other projects, so it will not be deleted");
			return undef;
		}
		studios::delete( $config, $entry );
		uac::print_info("Studio deleted");
	}
}

sub save_studio {
	my $config  = shift;
	my $request = shift;

	my $params      = $request->{params}->{checked};
	my $permissions = $request->{permissions};
	unless ( $permissions->{update_studio} == 1 ) {
		uac::permissions_denied('update_studio');
		return;
	}

	#filter entry for studio columns
	my $columns = studios::get_columns($config);
	my $entry   = {};
	for my $param ( keys %$params ) {
		if ( defined $columns->{$param} ) {
			$entry->{$param} = $params->{$param} || '';
		}
	}

	$config->{access}->{write} = 1;
	if ( ( defined $entry->{id} ) && ( $entry ne '' ) ) {
		studios::update( $config, $entry );
	} else {
		my $studios = studios::get( $config, { name => $entry->{name} } );
		if ( @$studios > 0 ) {
			uac::print_error("studio with name '$entry->{name}' already exists");
			return;
		}
		$entry->{id} = studios::insert( $config, $entry );

		project::assign_studio(
			$config,
			{
				project_id => $params->{project_id},
				studio_id  => $entry->{id}
			}
		);
	}

	#insert series for single events (if not already existing)
	my $studio_id     = $entry->{id};
	my $single_series = series::get(
		$config,
		{
			project_id        => $params->{project_id},
			studio_id         => $studio_id,
			has_single_events => 1
		}
	);
	if ( @$single_series == 0 ) {
		series::insert(
			$config,
			{
				project_id        => $params->{project_id},
				studio_id         => $studio_id,
				has_single_events => 1,
				count_episodes    => 0,
				series_name       => '_single_'
			}
		);
	}

	print qq{<div class="ok head">changes saved</div>};
}

sub show_studios {
	my $config  = shift;
	my $request = shift;

	my $params      = $request->{params}->{checked};
	my $permissions = $request->{permissions};

	my $studios = studios::get(
		$config,
		{
			project_id => $params->{project_id}
		}
	);
	$params->{studios} = $studios;
	$params->{loc} = localization::get( $config, { user => $params->{presets}->{user}, file => 'studios' } );
	uac::set_template_permissions( $permissions, $params );

	template::process( 'print', $params->{template}, $params );
}

sub check_params {
	my $params = shift;

	my $checked = {};

	#template
	my $template = '';
	$template = template::check( $params->{template}, 'studios' );
	$checked->{template} = $template;

	#actions
	my $action = '';
	if ( defined $params->{action} ) {
		if ( $params->{action} =~ /^(save|delete)$/ ) {
			$checked->{action} = $params->{action};
		}
	}

	for my $param ( 'name', 'description', 'location', 'stream', 'google_calendar' ) {
		if ( defined $params->{$param} ) {
			$checked->{$param} = $params->{$param};
		}
	}

	#numeric values
	for my $param ( 'project_id', 'studio_id', 'default_studio_id', 'id' ) {
		if ( ( defined $params->{$param} ) && ( $params->{$param} =~ /^\d+$/ ) ) {
			$checked->{$param} = $params->{$param};
		}
	}
	if ( defined $checked->{studio_id} ) {
		$checked->{default_studio_id} = $checked->{studio_id};
	} else {
		$checked->{studio_id} = -1;
	}

	return $checked;
}

