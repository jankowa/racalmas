#! /usr/bin/perl -w 

use warnings "all";
use strict;
use URI::Escape;
use Encode;
use Data::Dumper;
use MIME::Base64;
use Encode::Locale;

use params;
use config;
use log;
use template;
use db;
use auth;
use uac;

#use roles;
use time;
use markup;
use project;
use studios;
use events;
use series;
use series_dates;
use series_events;
use user_stats;
use localization;
use eventOps;

binmode STDOUT, ":utf8";

my $r = shift;
( my $cgi, my $params, my $error ) = params::get($r);

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
	},
};

#print STDERR Dumper($request)."\n";

#set user at params->presets->user
$request = uac::prepare_request( $request, $user_presets );
log::init($request);

$params = $request->{params}->{checked};

#show header
unless ( params::isJson() ) {
	my $headerParams = uac::set_template_permissions( $request->{permissions}, $params );
	$headerParams->{loc} = localization::get( $config, { user => $user, file => 'menu' } );
	template::process( 'print', template::check('default.html'), $headerParams );
}
return unless defined uac::check( $config, $params, $user_presets );

print q{
    <script src="js/datetime.js" type="text/javascript"></script>
    <script src="js/event.js" type="text/javascript"></script>
    <link rel="stylesheet" href="css/event.css" type="text/css" /> 
} unless (params::isJson);

if ( defined $params->{action} ) {
	if (   ( $params->{action} eq 'show_new_event' )
		|| ( $params->{action} eq 'show_new_event_from_schedule' ) )
	{
		show_new_event( $config, $request );
		return;
	}

	if (   ( $params->{action} eq 'create_event' )
		|| ( $params->{action} eq 'create_event_from_schedule' ) )
	{
		$params->{event_id} = create_event( $config, $request );
		unless ( defined $params->{event_id} ) {
			uac::print_error("failed");
			return;
		}
	}
	if ( $params->{action} eq 'get_json' ) {
		getJson( $config, $request );
		return;
	}
	if ( $params->{action} eq 'delete' ) { delete_event( $config, $request ) }
	if ( $params->{action} eq 'save' ) { save_event( $config, $request ) }
	if ( $params->{action} eq 'download' ) { download( $config, $request ) }
}
$config->{access}->{write} = 0;
show_event( $config, $request );

#show existing event for edit
sub show_event {
	my $config  = shift;
	my $request = shift;

	my $params      = $request->{params}->{checked};
	my $permissions = $request->{permissions};

	for my $attr ( 'project_id', 'studio_id', 'series_id', 'event_id' ) {
		unless ( defined $params->{$attr} ) {
			uac::print_error( "missing " . $attr . " to show event" );
			return;
		}
	}

	my $result = series_events::check_permission(
		$request,
		{
			permission => 'update_event_of_series,update_event_of_others',
			check_for  => [ 'studio', 'user', 'series', 'events' ],
			project_id => $params->{project_id},
			studio_id  => $params->{studio_id},
			series_id  => $params->{series_id},
			event_id   => $params->{event_id}
		}
	);
	unless ( $result eq '1' ) {
		uac::print_error($result);
		return undef;
	}
	$permissions->{update_event} = 1;
	print STDERR "check series permission ok\n";

	#TODO: move to JS
	my @durations = ();
	for my $duration ( @{ time::get_durations() } ) {
		my $entry = {
			name  => sprintf( "%02d:%02d", $duration / 60, $duration % 60 ),
			value => $duration
		};
		push @durations, $entry;
	}

	my $event = series::get_event(
		$config,
		{
			project_id => $params->{project_id},
			studio_id  => $params->{studio_id},
			series_id  => $params->{series_id},
			event_id   => $params->{event_id}
		}
	);
	unless ( defined $event ) {
		uac::print_error("event not found");
	}
	#print STDERR "show:".Dumper($event->{draft});

	my $editLock = 1;
	if ( ( defined $permissions->{update_event_after_week} ) && ( $permissions->{update_event_after_week} eq '1' ) ) {
		$editLock = 0;
	} else {
		$editLock = 0
		  if (
			series::is_event_older_than_days(
				$config,
				{
					project_id => $params->{project_id},
					studio_id  => $params->{studio_id},
					series_id  => $params->{series_id},
					event_id   => $params->{event_id},
					max_age    => 14
				}
			) == 0
		  );
	}

	# for rerun, deprecated
	if ( defined $params->{source_event_id} ) {
		my $event2 = series::get_event(
			$config,
			{
				allow_any => 1,

				#project_id => $params->{project_id},
				#studio_id  => $params->{studio_id},
				#series_id  => $params->{series_id},
				event_id    => $params->{source_event_id},
				draft       => 0,
			}
		);
		if ( defined $event2 ) {
			for my $attr (
				'title', 'user_title',         'excerpt',     'user_excerpt', 'content', 'topic',
				'image', 'live no_event_sync', 'podcast_url', 'archive_url'
			  )
			{
				$event->{$attr} = $event2->{$attr};
			}
			$event->{recurrence} = eventOps::getRecurrenceBaseId($event2);
			$event->{rerun}      = 1;
		}
	}

	$event->{rerun} = 1 if ( $event->{rerun} =~ /a-z/ );

	$event->{series_id} = $params->{series_id};
	$event->{duration}  = events::get_duration( $config, $event );
	$event->{durations} = \@durations;
	if ( defined $event->{duration} ) {
		for my $duration ( @{ $event->{durations} } ) {
			$duration->{selected} = 1 if ( $event->{duration} eq $duration->{value} );
		}
	}
	$event->{start} =~ s/(\d\d:\d\d)\:\d\d/$1/;
	$event->{end} =~ s/(\d\d:\d\d)\:\d\d/$1/;

	# overwrite event with old one
	#my $series_events=get_series_events($config,{
	#    project_id => $params->{project_id},
	#    studio_id  => $params->{studio_id},
	#    series_id  => $params->{series_id}
	#});
	#my @series_events=();
	#for my $series_event (@$series_events){
	#    push @series_events, $series_event if ($series_event->{start} lt $event->{start});
	#}
	#$params->{series_events}=\@series_events;

	# get all series
	#my $series=series::get(
	#    $config,{
	#        project_id => $params->{project_id},
	#        studio_id  => $params->{studio_id},
	#    }
	#);
	#for my $serie (@$series){
	#    $serie->{selected}=1 if $params->{series_id}==$serie->{series_id};
	#}
	#$params->{series}=$series;

	# get event series
	my $series = series::get(
		$config,
		{
			project_id => $params->{project_id},
			studio_id  => $params->{studio_id},
			series_id  => $params->{series_id}
		}
	);
	if ( @$series == 1 ) {
		$event->{has_single_events} = $series->[0]->{has_single_events};
	}

	#$event->{rerun}=1 if ((defined $event->{rerun})&&($event->{rerun}ne'0')&&($event->{rerun}ne''));

	my $users = series::get_users(
		$config,
		{
			project_id => $params->{project_id},
			studio_id  => $params->{studio_id},
			series_id  => $params->{series_id}
		}
	);
	$params->{series_users} = $users;

	#print STDERR Dumper($users);
	$params->{series_users_email_list} = join( ',', ( map { $_->{email} } (@$users) ) );
	$params->{series_user_names} = join( ' und ', ( map { ( split( /\s+/, $_->{full_name} ) )[0] } (@$users) ) );

	for my $permission ( sort keys %{$permissions} ) {
		$params->{'allow'}->{$permission} = $permissions->{$permission};
	}

	for my $key ( keys %$event ) {
		$params->{$key} = $event->{$key};
	}
	$params->{event_edited} = 1 if ( ( $params->{action} eq 'save' ) && ( !( defined $params->{error} ) ) );
	$params->{event_edited} = 1 if ( $params->{action} eq 'delete' );
	$params->{event_edited} = 1 if ( ( $params->{action} eq 'create_event' ) && ( !( defined $params->{error} ) ) );
	$params->{event_edited} = 1 if ( ( $params->{action} eq 'create_event_from_schedule' ) && ( !( defined $params->{error} ) ) );
	$params->{user} = $params->{presets}->{user};

	# remove all edit permissions if event is over for more than 2 weeks
	if ( $editLock == 1 ) {
		for my $key ( keys %$params ) {
			unless ( $key =~ /create_download/ ) {
				delete $params->{allow}->{$key} if $key =~ /^(update|delete|create|assign)/;
			}
		}
		$params->{edit_lock} = 1;
	}

	#print STDERR Dumper($params);
	$params->{loc} = localization::get( $config, { user => $params->{presets}->{user}, file => 'event' } );
	template::process( 'print', template::check('edit_event'), $params );
}

sub getJson {
	my $config  = shift;
	my $request = shift;

	my $params      = $request->{params}->{checked};
	my $permissions = $request->{permissions};

	for my $attr ( 'project_id', 'studio_id', 'series_id', 'event_id' ) {
		unless ( defined $params->{$attr} ) {
			uac::print_error( "missing " . $attr . " to show event" );
			return;
		}
	}

	my $result = series_events::check_permission(
		$request,
		{
			permission => 'update_event_of_series,update_event_of_others',
			check_for  => [ 'studio', 'user', 'series', 'events' ],
			project_id => $params->{project_id},
			studio_id  => $params->{studio_id},
			series_id  => $params->{series_id},
			event_id   => $params->{event_id}
		}
	);
	unless ( $result eq '1' ) {
		uac::print_error($result);
		return undef;
	}
	$permissions->{update_event} = 1;

	my $event = series::get_event(
		$config,
		{
			project_id => $params->{project_id},
			studio_id  => $params->{studio_id},
			series_id  => $params->{series_id},
			event_id   => $params->{event_id}
		}
	);
	unless ( defined $event ) {
		uac::print_error("event not found");
	}

	$event->{rerun} = 1 if ( $event->{rerun} =~ /a-z/ );
	$event->{series_id} = $params->{series_id};
	$event->{start} =~ s/(\d\d:\d\d)\:\d\d/$1/;
	$event->{end} =~ s/(\d\d:\d\d)\:\d\d/$1/;

	# get event series
	my $series = series::get(
		$config,
		{
			project_id => $params->{project_id},
			studio_id  => $params->{studio_id},
			series_id  => $params->{series_id}
		}
	);

	if ( @$series == 1 ) {
		my $serie = $series->[0];
		$event->{has_single_events} = $serie->{has_single_events};
		if ( $event->{has_single_events} eq '1' ) {
			$event->{has_single_events} = 1;
			$event->{series_name}       = undef;
			$event->{episode}           = undef;
		}
	}

	$event->{duration} = events::get_duration( $config, $event );

	# for rerun
	if ( $params->{get_rerun} == 1 ) {
		$event->{rerun}      = 1;
		$event->{recurrence} = eventOps::getRecurrenceBaseId($event);

		#$event=events::calc_dates($config, $event);
	}

	#print to_json($event);
	template::process( 'print', 'json-p', $event );
}

#show new event from schedule
sub show_new_event {
	my $config  = shift;
	my $request = shift;

	my $params      = $request->{params}->{checked};
	my $permissions = $request->{permissions};

	if ( $params->{action} eq 'show_new_event' ) {
		$params->{show_new_event} = 1;
		unless ( $permissions->{create_event} == 1 ) {
			uac::permissions_denied('create_event');
			return;
		}
	} elsif ( $params->{action} eq 'show_new_event_from_schedule' ) {
		$params->{show_new_event_from_schedule} = 1;
		unless ( $permissions->{create_event_from_schedule} == 1 ) {
			uac::permissions_denied('create_event_from_schedule');
			return;
		}
	} else {
		uac::print_error("invalid action");
		return 1;
	}

	# check for missing parameters
	my $required_fields = [ 'project_id', 'studio_id', 'series_id' ];
	push @$required_fields, 'start_date' if ( $params->{action} eq 'show_new_event_from_schedule' );

	my $event = {};
	for my $attr (@$required_fields) {
		unless ( defined $params->{$attr} ) {
			uac::print_error( "missing " . $attr );
			return;
		}
		$event->{$attr} = $params->{$attr};
	}

	my $serie = eventOps::setAttributesFromSeriesTemplate( $config, $params, $event );

	if ( $params->{action} eq 'show_new_event_from_schedule' ) {
		eventOps::setAttributesFromSchedule( $config, $params, $event );
	} else {
		eventOps::setAttributesForCurrentTime( $serie, $event );
	}

	if ( defined $params->{source_event_id} ) {

		#overwrite by existing event (rerun)
		eventOps::setAttributesFromOtherEvent( $config, $params, $event );
	}

	$event = events::calc_dates( $config, $event );

	if ( $serie->{has_single_events} eq '1' ) {
		$event->{has_single_events} = 1;
		$event->{series_name}       = undef;
		$event->{episode}           = undef;
	}

	#get next episode
	$event->{episode} = series::get_next_episode(
		$config,
		{
			project_id => $params->{project_id},
			studio_id  => $params->{studio_id},
			series_id  => $params->{series_id},
		}
	);
	delete $event->{episode} if $event->{episode} == 0;

	$event->{disable_event_sync} = 1;
	$event->{published}          = 1;
	$event->{new_event}          = 1;

	#copy event to template params
	for my $key ( keys %$event ) {
		$params->{$key} = $event->{$key};
	}

	#add duration selectbox
	#TODO: move to javascript
	my @durations = ();
	for my $duration ( @{ time::get_durations() } ) {
		my $entry = {
			name  => sprintf( "%02d:%02d", $duration / 60, $duration % 60 ),
			value => $duration
		};
		push @durations, $entry;
	}
	$params->{durations} = \@durations;

	#set duration preset
	for my $duration ( @{ $params->{durations} } ) {
		$duration->{selected} = 1 if ( $event->{duration} eq $duration->{value} );
	}

	#check user permissions and then:
	$permissions->{update_event} = 1;

	#set permissions to template
	for my $permission ( keys %{ $request->{permissions} } ) {
		$params->{'allow'}->{$permission} = $request->{permissions}->{$permission};
	}

	$params->{loc} = localization::get( $config, { user => $params->{presets}->{user}, file => 'event,comment' } );
	template::process( 'print', template::check('edit_event'), $params );

	#print '<pre>'.Dumper($params).'</pre>';
}

sub delete_event {
	my $config  = shift;
	my $request = shift;

	my $params      = $request->{params}->{checked};
	my $permissions = $request->{permissions};

	my $event = {};
	for my $attr ( 'project_id', 'studio_id', 'series_id', 'event_id' ) {
		unless ( defined $params->{$attr} ) {
			uac::print_error( "missing " . $attr );
			return;
		}
		$event->{$attr} = $params->{$attr};
	}

	my $result = series_events::check_permission(
		$request,
		{
			permission => 'delete_event',
			check_for  => [ 'studio', 'user', 'series', 'events', 'event_age' ],
			project_id => $params->{project_id},
			studio_id  => $event->{studio_id},
			series_id  => $event->{series_id},
			event_id   => $event->{event_id}
		}
	);
	unless ( $result eq '1' ) {
		uac::print_error($result);
		return undef;
	}

	$config->{access}->{write} = 1;

	#set user to be added to history
	$event->{user} = $params->{presets}->{user};
	$result = series_events::delete_event( $config, $event );
	unless ( defined $result ) {
		uac::print_error('could not delete event');
		return undef;
	}

	user_stats::increase(
		$config,
		'delete_events',
		{
			project_id => $event->{project_id},
			studio_id  => $event->{studio_id},
			series_id  => $event->{series_id},
			user       => $event->{user}
		}
	);

	uac::print_info("event deleted");
}

#save existing event
sub save_event {
	my $config  = shift;
	my $request = shift;

	my $params      = $request->{params}->{checked};
	my $permissions = $request->{permissions};

	for my $attr ( 'project_id', 'studio_id', 'series_id', 'event_id' ) {
		unless ( defined $params->{$attr} ) {
			uac::print_error( "missing " . $attr . " to show event" );
			return;
		}
	}

	#print Dumper($params);
	my $start = $params->{start_date}, my $end = time::add_minutes_to_datetime( $params->{start_date}, $params->{duration} );

	#check permissions
	my $options = {
		permission => 'update_event_of_series,update_event_of_others',
		check_for  => [ 'studio', 'user', 'series', 'events', 'studio_timeslots', 'event_age' ],
		project_id => $params->{project_id},
		studio_id  => $params->{studio_id},
		series_id  => $params->{series_id},
		event_id   => $params->{event_id},
		draft      => $params->{draft},
		start      => $start,
		end        => $end,
	};

	my $result = series_events::check_permission( $request, $options );
	unless ( $result eq '1' ) {
		uac::print_error($result);
		return;
	}

	#changed columns depending on permissions
	my $entry = { id => $params->{event_id} };

	my $found = 0;

	#content fields
	for my $key ( 'content', 'topic', 'title', 'excerpt', 'episode', 'image', 'podcast_url', 'archive_url' ) {
		next unless defined $permissions->{ 'update_event_field_' . $key };
		if ( $permissions->{ 'update_event_field_' . $key } eq '1' ) {
			$entry->{$key} = $params->{$key} if defined $params->{$key};
			$found++;
		}
	}

	#user extension fields
	for my $key ( 'title', 'excerpt' ) {
		next unless defined $permissions->{ 'update_event_field_' . $key . '_extension' };
		if ( $permissions->{ 'update_event_field_' . $key . '_extension' } eq '1' ) {
			$entry->{ 'user_' . $key } = $params->{ 'user_' . $key } if defined $params->{ 'user_' . $key };
			$found++;
		}
	}

	#status field
	for my $key ( 'live', 'published', 'playout', 'archived', 'rerun', 'disable_event_sync', 'draft' ) {
		next unless defined $permissions->{ 'update_event_status_' . $key };
		if ( $permissions->{ 'update_event_status_' . $key } eq '1' ) {
			$entry->{$key} = $params->{$key} || 0;
			$found++;
		}
	}

	$entry->{modified_by} = $params->{presets}->{user};

	#get event from database (for history)
	my $event = series::get_event(
		$config,
		{
			project_id => $params->{project_id},
			studio_id  => $params->{studio_id},
			series_id  => $params->{series_id},
			event_id   => $params->{event_id}
		}
	);
	unless ( defined $event ) {
		uac::print_error("event not found");
		return;
	}

	$config->{access}->{write} = 1;

	#update content
	if ( $found > 0 ) {
		$entry = series_events::save_content( $config, $entry );
		for my $key ( keys %$entry ) {
			$event->{$key} = $entry->{$key};
		}
	}

	#update time
	if ( ( defined $permissions->{update_event_time} ) && ( $permissions->{update_event_time} eq '1' ) ) {
		my $entry = {
			id         => $params->{event_id},
			start_date => $params->{start_date},
			duration   => $params->{duration},

			#        end                  => $params->{end_date} ,
		};
		$entry = series_events::save_event_time( $config, $entry );
		for my $key ( keys %$entry ) {
			$event->{$key} = $entry->{$key};
		}
	}

	$event->{project_id} = $params->{project_id};
	$event->{studio_id}  = $params->{studio_id};
	$event->{series_id}  = $params->{series_id};
	$event->{event_id}   = $params->{event_id};
	$event->{user}       = $params->{presets}->{user};

	#update recurrences
	series::update_recurring_events( $config, $event );

	#update history
	event_history::insert( $config, $event );

	user_stats::increase(
		$config,
		'update_events',
		{
			project_id => $event->{project_id},
			studio_id  => $event->{studio_id},
			series_id  => $event->{series_id},
			user       => $event->{user}
		}
	);

	#print "error" unless (defined $result);
	$config->{access}->{write} = 0;
	uac::print_info("event saved");
}

sub create_event {
	my $config  = shift;
	my $request = shift;

	my $params      = $request->{params}->{checked};
	my $permissions = $request->{permissions};

	my $checklist = [ 'studio', 'user', 'create_events', 'studio_timeslots' ];
	if ( $params->{action} eq 'create_event_from_schedule' ) {
		push @$checklist, 'schedule' if $params->{action} eq 'create_event_from_schedule';
	}

	my $start = $params->{start_date}, my $end = time::add_minutes_to_datetime( $params->{start_date}, $params->{duration} );

	my $result = series_events::check_permission(
		$request,
		{
			permission => 'create_event,create_event_of_series',
			check_for  => $checklist,
			project_id => $params->{project_id},
			studio_id  => $params->{studio_id},
			series_id  => $params->{series_id},
			start_date => $params->{start_date},
			draft      => $params->{draft},
			start      => $start,
			end        => $end,
		}
	);

	#print Dumper("            start_date => $params->{start_date}");
	unless ( $result eq '1' ) {
		uac::print_error($result);
		return undef;
	}

	#get series name from series
	my $series = series::get(
		$config,
		{
			project_id => $params->{project_id},
			studio_id  => $params->{studio_id},
			series_id  => $params->{series_id},
		}
	);
	if ( @$series != 1 ) {
		uac::print_error("series not found");
		return undef;
	}
	my $serie = $series->[0];

	#get studio location from studios
	my $studios = studios::get(
		$config,
		{
			project_id => $params->{project_id},
			studio_id  => $params->{studio_id}
		}
	);
	unless ( defined $studios ) {
		uac::print_error("studio not found");
		return undef;
	}
	unless ( @$studios == 1 ) {
		uac::print_error("studio not found");
		return undef;
	}
	my $studio = $studios->[0];

	$config->{access}->{write} = 1;

	#insert event content and save history
	my $event_id = series_events::insert_event(
		$config,
		{
			project_id => $params->{project_id},
			studio     => $studio,
			serie      => $serie,
			event      => $params,
			user       => $params->{presets}->{user}
		}
	);
	uac::print_error("could not insert event") if $event_id <= 0;

	#assign event to series
	$result = series::assign_event(
		$config,
		{
			project_id => $params->{project_id},
			studio_id  => $params->{studio_id},
			series_id  => $params->{series_id},
			event_id   => $event_id
		}
	);
	uac::print_error("could not assign event") unless defined $result;

	#update recurrences
	my $event = $params;
	$event->{event_id} = $event_id;
	series::update_recurring_events( $config, $event );

	# update user stats
	user_stats::increase(
		$config,
		'create_events',
		{
			project_id => $params->{project_id},
			studio_id  => $params->{studio_id},
			series_id  => $params->{series_id},
			user       => $params->{presets}->{user}
		}
	);

	#forward to edit event
	#print STDERR Dumper($event_id);
	#$params->{event_id}=$event_id;
	uac::print_info("event created");
	return $event_id;
}

#TODO: replace permission check with download
sub download {
	my $config  = shift;
	my $request = shift;

	my $params      = $request->{params}->{checked};
	my $permissions = $request->{permissions};

	my $result = series_events::check_permission(
		$request,
		{
			permission => 'update_event_of_series,update_event_of_others',
			check_for  => [ 'studio', 'user', 'series', 'events' ],
			project_id => $params->{project_id},
			studio_id  => $params->{studio_id},
			series_id  => $params->{series_id},
			event_id   => $params->{event_id}
		}
	);
	unless ( $result eq '1' ) {
		uac::print_error($result);
		return undef;
	}
	$permissions->{update_event} = 1;

	my $request2 = {
		params => {
			checked => events::check_params(
				$config,
				{
					event_id => $params->{event_id},
					template => 'no',
					limit    => 1,
				}
			)
		},
		config      => $request->{config},
		permissions => $request->{permissions}
	};

	$request2->{params}->{checked}->{published} = 'all';
	my $events   = events::get( $config, $request2 );
	my $event    = $events->[0];
	my $datetime = $event->{start_datetime};
	if ( $datetime =~ /(\d\d\d\d\-\d\d\-\d\d)[ T](\d\d)\:(\d\d)/ ) {
		$datetime = $1 . '\ ' . $2 . '_' . $3;
	} else {
		print STDERR "event.cgi::download no valid datetime found $datetime\n";
		return;
	}
	my $archive_dir = $config->{locations}->{local_archive_dir};
	my $archive_url = $config->{locations}->{local_archive_url};
	print STDERR "archive_dir: " . $archive_dir . "\n";
	print STDERR "archive_url: " . $archive_url . "\n";
	print STDERR "event.cgi::download look for : $archive_dir/$datetime*.mp3\n";
	my @files = glob( $archive_dir . '/' . $datetime . '*.mp3' );

	#print STDERR Dumper(\@files);
	if ( @files > 0 ) {
		my $file = $files[0];
		my $key  = int( rand(99999999999999999) );
		$key = encode_base64($key);
		$key =~ s/[^a-zA-Z0-9]//g;

		#decode filename
		$file = Encode::decode( "UTF-8", $file );

		my $cmd = "ln -s '" . $file . "' '" . $archive_dir . '/' . $key . ".mp3'";
		my $url = $archive_url . '/' . $key . '.mp3';

		#print $cmd."\n";
		print `$cmd`;

		$request->{params}->{checked}->{download} =
		    "Hallo,\n\n"
		  . "anbei der Mitschnitt fuer\n"
		  . $event->{start_date_name} . ", "
		  . $event->{start_time_name} . " - "
		  . $event->{series_name} . ' - '
		  . $event->{title} . ":\n"
		  . $url . "\n"
		  . "\nDer Link wird nach 7 Tagen geloescht. (bitte nicht weitergeben)\n"
		  . "Gruss, Peter\n";
	}
}

sub check_params {
	my $params = shift;

	my $checked  = {};
	my $template = '';
	$checked->{template} = template::check( $params->{template}, 'series' );

	my $debug = $params->{debug} || '';
	if ( $debug =~ /([a-z\_\,]+)/ ) {
		$debug = $1;
	}
	$checked->{debug} = $debug;

	#numeric values
	for my $param ( 'id', 'project_id', 'studio_id', 'default_studio_id', 'user_id', 'series_id', 'event_id', 'source_event_id', 'episode' )
	{
		if ( ( defined $params->{$param} ) && ( $params->{$param} =~ /^\d+$/ ) ) {
			$checked->{$param} = $params->{$param};
		}
	}

	if ( defined $checked->{studio_id} ) {
		$checked->{default_studio_id} = $checked->{studio_id};
	} else {
		$checked->{studio_id} = -1;
	}

	#scalars
	for my $param ( 'studio', 'search', 'from', 'till', 'hide_series' ) {
		if ( defined $params->{$param} ) {
			$checked->{$param} = $params->{$param};
			$checked->{$param} =~ s/^\s+//g;
			$checked->{$param} =~ s/\s+$//g;
		}
	}

	#numbers
	for my $param ( 'duration', 'recurrence' ) {
		if ( ( defined $params->{$param} ) && ( $params->{$param} =~ /(\d+)/ ) ) {
			$checked->{$param} = $1;
		}
	}

	#checkboxes
	for my $param ( 'live', 'published', 'playout', 'archived', 'rerun', 'draft', 'disable_event_sync', 'get_rerun' ) {
		if ( ( defined $params->{$param} ) && ( $params->{$param} =~ /([01])/ ) ) {
			$checked->{$param} = $1;
			# print STDERR "check $param = $1\n";
		}
	}

	#strings
	for my $param (
		'series_name',  'title',      'excerpt',      'content',     'topic', 'program', 'category', 'image',
		'user_content', 'user_title', 'user_excerpt', 'podcast_url', 'archive_url'
	  )
	{
		if ( defined $params->{$param} ) {

			#$checked->{$param}=uri_unescape();
			$checked->{$param} = $params->{$param};
			$checked->{$param} =~ s/^\s+//g;
			$checked->{$param} =~ s/\s+$//g;
		}
	}

	#dates
	for my $param ( 'start_date', 'end_date' ) {
		if ( ( defined $params->{$param} ) && ( $params->{$param} =~ /(\d\d\d\d\-\d\d\-\d\d \d\d\:\d\d)/ ) ) {
			$checked->{$param} = $1 . ':00';
		}
	}

	#actions and roles
	$checked->{action} = '';
	if ( defined $params->{action} ) {
		if ( $params->{action} =~
			/^(save|delete|download|show_new_event|show_new_event_from_schedule|create_event|create_event_from_schedule|get_json)$/ )
		{
			$checked->{action} = $params->{action};
		}
	}

	#print STDERR Dumper($checked);
	return $checked;
}

__DATA__

#requires studio_id,series_id,location
sub get_series_events{
    my $config=shift;
    my $options=shift;

    return undef unless defined $options->{project_id};
    return undef unless defined $options->{studio_id};
    return undef unless defined $options->{series_id};

    $options->{template}= 'no'; # deprecated
    $options->{limit}   = 200;  # deprecated
    $options->{get}     = 'no_content'; # deprecated
    $options->{archive} = 'all'; # deprecated

   	my $events=series::get_events($config, $options);
    return $events;
}

