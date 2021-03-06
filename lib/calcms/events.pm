use warnings "all";
use strict;

use DBI;
use template;

use config;
use time;
use db;
use cache;
use markup;
use log;

package events;
use Data::Dumper;
use project;
use studios;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(
	init 
	get_cached_or_render 
	get 
	modify_results 
	get_query 
	render 
	get_running_event_id 
	delete 
	check_params 
	configure_cache 
	get_duration 
	calc_dates 
	get_keys 
	add_recordings
);
our %EXPORT_TAGS = ( 'all' => [@EXPORT_OK] );

sub init {
}

sub get_cached_or_render {

	#    my $response=$_[0];
	my $config  = $_[1];
	my $request = $_[2];

	my $params = $request->{params}->{checked};
	my $debug  = $config->{system}->{debug};

	my $cache = {};
	if ( $config->{cache}->{use_cache} == 1 ) {
		events::configure_cache($config);
		$cache = cache::load( $config, $params );
		log::write( $config, 'cache', $cache->{action} );
		if ( defined $cache->{content} ) {
			$_[0] = $cache->{content};
			return;
		}
	}

	my $results = events::get( $config, $request );
	events::render( $_[0], $config, $request, $results );

	#write to cache
	if ( $config->{cache}->{use_cache} == 1 ) {

		#todo:put out reference only
		log::write( $config, 'cache', $cache );
		$cache->{content} = $_[0];
		cache::save($cache);
	}
	log::mem( $config, 'events not_cached' ) if ( $debug > 2 );
	return $_[0];
}

sub get {
	my $config  = shift;
	my $request = shift;

	my $debug = $config->{system}->{debug};

	my $dbh = db::connect( $config, $request );

	( my $query, my $bind_values ) = events::get_query( $dbh, $config, $request );

	#print STDERR Dumper($query).Dumper($bind_values)."\n";

	my $results = db::get( $dbh, $$query, $bind_values );

    #$results = events::add_recordings($dbh, $config, $request, $results);

	#print STDERR Dumper($results);
	$results = events::modify_results( $dbh, $config, $request, $results );

	return $results;
}

sub modify_results {
	my $dbh     = shift;
	my $config  = shift;
	my $request = shift;
	my $results = shift;

	my $params = $request->{params}->{checked};

	my $running_event_id = 0;
	my $projects         = {};
	my $studios          = {};

	#    print $running_event_id." ".$running_events->[0]->{start}." ".$running_events->[0]->{title} if ($debug ne'');
	my $time_diff = '';
	if ( scalar @$results > 0 ) {
		$results->[0]->{__first__} = 1;
		$results->[-1]->{__last__} = 1;
		$running_event_id          = events::get_running_event_id($dbh);
	}

	if ( ( defined $params->{template} ) && ( $params->{template} =~ /\.xml/ ) ) {
		$time_diff = time::utc_offset( $config->{date}->{time_zone} );
		$time_diff =~ s/(\d\d)(\d\d)/$1\:$2/g;
	}

	my $previous_result = { start_date => '' };
	my $counter = 1;
	for my $result (@$results) {
		if ( defined $params->{template} ) {
			if ( $params->{template} =~ /\.ics$/ ) {
				$result->{content_ical} =
				  markup::plain_to_ical( $result->{content} );
				$result->{title_ical} =
				  markup::plain_to_ical( $result->{title} );
				$result->{user_title_ical} =
				  markup::plain_to_ical( $result->{user_title} );
				$result->{excerpt_ical} =
				  markup::plain_to_ical( $result->{excerpt} );
				$result->{user_excerpt_ical} =
				  markup::plain_to_ical( $result->{user_excerpt} );
				$result->{series_name} =
				  markup::plain_to_ical( $result->{series_name} );
				$result->{created_at} =~ s/ /T/gi;
				$result->{created_at} =~ s/[\:\-]//gi;
				$result->{modified_at} =~ s/ /T/gi;
				$result->{modified_at} =~ s/[\:\-]//gi;

			} elsif ( $params->{template} =~ /\.atom\.xml/ ) {
				$result->{excerpt} = '' unless defined( $result->{excerpt} );
				$result->{excerpt} = "lass dich ueberraschen"
				  if ( $result->{excerpt} eq '' );

				#                $result->{excerpt}    =markup::plain_to_xml($result->{excerpt});
				#                $result->{title}    =markup::plain_to_xml($result->{title});
				#                $result->{series_name}    =markup::plain_to_xml($result->{series_name});
				#                $result->{program}    =markup::plain_to_xml($result->{program});

				$result->{created_at} =~ s/ /T/gi;
				$result->{created_at} .= $time_diff;
				$result->{modified_at} =~ s/ /T/gi;
				$result->{modified_at} .= $time_diff;
			} elsif ( $params->{template} =~ /\.rss\.xml/ ) {
				$result->{excerpt} = '' unless defined( $result->{excerpt} );
				$result->{excerpt} = "lass dich ueberraschen"
				  if ( $result->{excerpt} eq '' );

				#                $result->{excerpt}    =markup::plain_to_xml($result->{excerpt});
				#                $result->{title}    =markup::plain_to_xml($result->{title});
				#                $result->{series_name}    =markup::plain_to_xml($result->{series_name});
				#                $result->{program}    =markup::plain_to_xml($result->{program});
				#print STDERR "created:$result->{created_at} modified:$result->{modified_at}\n";
				$result->{modified_at} =
				  time::datetime_to_rfc822( $result->{modified_at} );
				if ( $result->{created_at} =~ /[1-9]/ ) {
					$result->{created_at} =
					  time::datetime_to_rfc822( $result->{created_at} );
				} else {
					$result->{created_at} = $result->{modified_at};
				}

			}
		}
		$result->{series_name} ||= '';
		$result->{series_name} = '' if $result->{series_name} eq '_single_';

		$result->{rerun} = '' unless defined $result->{rerun};

		if ( $result->{title} =~ /\#(\d+)([a-z])?\s*$/ ) {
			$result->{episode} = $1 unless defined $result->{episode};
			$result->{rerun} = $2 || '' unless ( $result->{rerun} =~ /\d/ );
			$result->{title} =~ s/\#\d+[a-z]?\s*$//;
			$result->{title} =~ s/\s+$//;
		}
		$result->{rerun} = '' if ( $result->{rerun} eq '0' );

		if (   ( defined $result->{recurrence_count} )
			&& ( $result->{recurrence_count} > 0 ) )
		{
			$result->{recurrence_count_alpha} =
			  markup::base26( $result->{recurrence_count} + 1 );
			$result->{recurrence_id} = $result->{recurrence};
		} else {
			$result->{recurrence_count_alpha} = '';
			$result->{recurrence_count}       = '';
		}

		# set title keys
		my $keys = get_keys($result);
		for my $key ( keys %$keys ) {
			$result->{$key} = $keys->{$key};
		}

		$result = calc_dates( $config, $result, $params, $previous_result, $time_diff );

		$result->{event_uri} = '';
		if ( ( defined $result->{program} ) && ( $result->{program} ne '' ) ) {
			$result->{event_uri} .= $result->{program};
			$result->{event_uri} .= '-'
			  if ( ( $result->{series_name} ne '' )
				|| ( $result->{title} ne '' ) );
		}
		if ( $result->{series_name} ne '' ) {
			$result->{event_uri} .= $result->{series_name};
			$result->{event_uri} .= '-' if ( $result->{title} ne '' );
		}
		$result->{event_uri} .= $result->{title} if ( $result->{title} ne '' );
		$result->{event_uri} =~ s/\#/Nr./g;
		$result->{event_uri} =~ s/\&/und/g;
		$result->{event_uri} =~ s/\//\%2f/g;
		$result->{event_uri} =~ s/[?]//g;

		$result->{rds_title} = $result->{event_uri};
		$result->{rds_title} =~ s/[^a-zA-Z0-9\-]/\_/gi;
		$result->{rds_title} =~ s/\_{2,99}/\_/gi;
		$result->{rds_title} = substr( $result->{rds_title}, 0, 63 );

		#        $result->{event_id}=$result->{id};

		$result->{base_url}         = $request->{base_url};
		$result->{base_domain}      = $config->{locations}->{base_domain};
		$result->{static_files_url} = $config->{locations}->{static_files_url};
		$result->{source_base_url}  = $config->{locations}->{source_base_url};
		$result->{cache_base_url}   = $config->{cache}->{base_url};

		$result->{is_running} = 1
		  if ( $running_event_id eq $result->{event_id} );
		$result->{one_comment} = 1 if ( $result->{comment_count} == 1 );
		$result->{no_comment}  = 1 if ( $result->{comment_count} == 0 );

		#fix image url
		if ( defined $result->{image} ) {
			$result->{thumb} = $result->{image};
			$result->{icon}  = $result->{image};

			$result->{image} =~ s/thumbs/images/g;
			$result->{image} =~ s/icons/images/g;

			#fix thumbs url
			$result->{thumb} =~ s/images/thumbs/s;
			$result->{thumb} =~ s/icons/thumbs/s;

			#fix icon url
			$result->{icon} =~ s/thumbs/icons/s;
			$result->{icon} =~ s/images/icons/s;
		}

		$result->{location_css} = $result->{location} || '';
		$result->{location_css} = lc( $result->{location_css} );
		$result->{location_css} =~ s/\.//g;
		$result->{location_css} =~ s/\s//g;
		$result->{ 'location_label_' . $result->{location_css} } = 1;

		# add project by name
		my $project_name = $result->{project};
		if ( defined $project_name ) {

			#print STDERR "found project:$project_name\n";
			unless ( defined $projects->{$project_name} ) {
				my $results = project::get( $config, { name => $project_name } );
				$projects->{$project_name} = $results->[0] || {};
			}
			my $project = $projects->{$project_name};
			for my $key ( keys %$project ) {
				$result->{ 'project_' . $key } = $project->{$key};
			}
		} else {
			print STDERR "events::get - unknown project for event $result->{id}\n";
		}

		#if project_id is set add columns from project (cached)
		my $project_id = $result->{project_id};
		if ( defined $project_id ) {
			unless ( defined $projects->{$project_id} ) {
				my $results = project::get( $config, { project_id => $project_id } );
				$projects->{$project_id} = $results->[0] || {};
			}
			my $project = $projects->{$project_id};
			for my $key ( keys %$project ) {
				$result->{ 'project_' . $key } = $project->{$key};
			}
		}

		#if studio_id is set add columns from studio (cached)
		my $studio_id = $result->{studio_id};
		if ( defined $studio_id ) {
			unless ( defined $studios->{$studio_id} ) {
				my $results = studios::get( $config, { studio_id => $studio_id } );
				$studios->{$studio_id} = $results->[0] || {};
			}
			my $studio = $studios->{$studio_id};
			for my $key ( keys %$studio ) {
				$result->{ 'studio_' . $key } = $studio->{$key};
			}
		}

		#$result->{'project_title'}=$project->{title} if (defined $project->{title} && $project->{title} ne '');

		#print STDERR "project:'$project_name'\n";
		#print STDERR "title:'$result->{project_title}'\n";
		#use Data::Dumper;print STDERR Dumper($result);

		for my $name ( keys %{ $config->{mapping}->{events} } ) {
			my $val = '';
			if (   ( defined $name )
				&& ( defined $config->{mapping}->{events}->{$name} )
				&& ( defined $result->{$name} ) )
			{
				$val = $config->{mapping}->{events}->{$name}->{ $result->{$name} }
				  || '';
				$result->{ $name . '_mapped' } = $val if ( $val ne '' );
			}
		}

		#for my $name (keys %{$config->{controllers}}){
		#    $result->{"controller_$name"}=$config->{controllers}->{$name};
		#}

		$previous_result = $result;

		#print "Content-type:text/text\n\n";
		#use Data::Dumper;print STDERR Dumper($result);
		$result->{ 'counter_' . $counter } = 1;
		$counter++;

		if (   ( defined $params->{template} )
			&& ( $params->{template} =~ /(list|details)/ ) ){
	        if ( ( defined $result->{excerpt} ) && ( length($result->{excerpt}) > 250) ){
    	        $result->{excerpt} = substr($result->{excerpt}, 0, 250).'...';
	        }    

	        if ( (defined $result->{user_excerpt}) && (length($result->{user_excerpt}) > 250) ){
    	        $result->{user_excerpt} = substr($result->{user_excerpt}, 0, 250).'...';
	        }    
	    }

		#build content
		if (   ( defined $params->{template} )
			&& ( $params->{template} =~ /\.html/ ) )
		{
			if ( defined $result->{content} ) {
				$result->{content} =
				  markup::fix_line_ends( $result->{content} );
				$result->{content} =
				  markup::creole_to_html( $result->{content} );
				$result->{html_content} = $result->{content};

			}
			if ( defined $result->{topic} ) {
				$result->{topic}      = markup::fix_line_ends( $result->{topic} );
				$result->{topic}      = markup::creole_to_html( $result->{topic} );
				$result->{html_topic} = $result->{topic};
			}
		}

		#detect if images are in content or topic field
		my $image_in_text = 0;
		$image_in_text = 1
		  if ( ( defined $result->{content} )
			&& ( $result->{content} =~ /<img / ) );
		$image_in_text = 1
		  if ( ( defined $result->{topic} )
			&& ( $result->{topic} =~ /<img / ) );
		$result->{no_image_in_text} = 1 if $image_in_text == 0;

		if (
			( defined $params->{template} )
			&& (   ( $params->{template} =~ /event_perl\.txt$/ )
				|| ( $params->{template} =~ /event_file_export\.txt$/ ) )

		  )
		{
			for my $key ( keys %$result ) {
				$result->{$key} =~ s/\|/\\\|/g if ( defined $result->{$key} );
			}

			#            $result->{content}='no';
		}

	}    # end for results
	add_recurrence_dates( $config, $results );
	return $results;
}

sub add_recurrence_dates {
	my $config  = shift;
	my $results = shift;

	# get unique list of recurrence ids from results
	my $recurrence_dates = {};
	for my $result (@$results) {
		next unless defined $result->{recurrence};
		next if $result->{recurrence} == 0;
		$recurrence_dates->{ $result->{recurrence} } = 0;
	}

	my @event_ids = keys %$recurrence_dates;
	return if @event_ids == 0;

	# query start date of recurrences
	my $conditions  = [];
	my $bind_values = [];
	for my $id (@event_ids) {
		push @$conditions,  '?';
		push @$bind_values, $id;
	}
	$conditions = join( ',', @$conditions );

	my $query = qq{
        select id event_id, start 
        from   calcms_events
        where  id in ($conditions)
    };

	#print STDERR Dumper($query);
	#return;
	my $dbh = db::connect($config);
	my $events = db::get( $dbh, $query, $bind_values );

	# store start dates by recurrence id
	for my $event (@$events) {
		$recurrence_dates->{ $event->{event_id} } = $event->{start};
	}

	# set start dates to results
	for my $result (@$results) {
		next unless defined $result->{recurrence};
		next if $result->{recurrence} == 0;
		$result->{recurrence_date} =
		  $recurrence_dates->{ $result->{recurrence} };
	}

	#print STDERR Dumper($recurrence_dates);
}

sub calc_dates {
	my $config          = shift;
	my $result          = shift;
	my $params          = shift || {};
	my $previous_result = shift || {};
	my $time_diff       = shift || '';

	$result->{utc_offset} = $time_diff;
	$result->{time_zone}  = $config->{date}->{time_zone};
	my $language = $config->{date}->{language} || 'en';

	$result->{start_datetime} = $result->{start};
	$result->{start_datetime} =~ s/ /T/gi;
	if ( $result->{start_datetime} =~ /(\d\d\d\d)\-(\d\d)\-(\d\d)T(\d\d)\:(\d\d)/ ) {
		$result->{start_year}   = $1;
		$result->{start_month}  = $2;
		$result->{start_day}    = $3;
		$result->{start_hour}   = $4;
		$result->{start_minute} = $5;
	}

	unless ( defined $result->{day} ) {
		my $d    = time::datetime_to_array( $result->{start} );
		my $hour = $d->[3];
		if ( ( defined $hour ) && ( $hour < 6 ) ) {
			$result->{day} = time::add_days_to_date( $result->{start}, -1 );
		} else {
			$result->{day} = time::datetime_to_date( $result->{start} );
		}
	}
	unless ( defined $result->{start_date} ) {
		$result->{start_date} = time::datetime_to_date( $result->{start} );
	}
	unless ( defined $result->{end_date} ) {
		$result->{end_date} = time::datetime_to_date( $result->{end} );
	}

	$result->{dtstart} = $result->{start_datetime};
	$result->{dtstart} =~ s/[\:\-]//gi;

	if (   ( defined $params->{template} )
		&& ( $params->{template} =~ /(\.txt|\.json)/ ) )
	{
		$result->{start_utc_epoch} = time::datetime_to_utc( $result->{start_datetime}, $config->{date}->{time_zone} );
	}
	if (   ( defined $params->{template} )
		&& ( $params->{template} =~ /(\.xml)/ ) )
	{
		$result->{start_datetime_utc} = time::datetime_to_utc_datetime( $result->{start_datetime}, $config->{date}->{time_zone} );
	}

	$result->{end_datetime} = $result->{end};
	$result->{end_datetime} =~ s/ /T/gi;

	$result->{dtend} = $result->{end_datetime};
	$result->{dtend} =~ s/[\:\-]//gi;

	if (   ( defined $params->{template} )
		&& ( $params->{template} =~ /(\.txt|\.json)/ ) )
	{
		$result->{end_utc_epoch} = time::datetime_to_utc( $result->{end_datetime}, $config->{date}->{time_zone} );
	}
	if (   ( defined $params->{template} )
		&& ( $params->{template} =~ /(\.xml)/ ) )
	{
		$result->{end_datetime_utc} = time::datetime_to_utc_datetime( $result->{end_datetime}, $config->{date}->{time_zone} );
	}

	if (   ( defined $previous_result )
		&& ( defined $previous_result->{start_date} )
		&& ( $result->{start_date} ne $previous_result->{start_date} ) )
	{
		$result->{is_first_of_day}         = 1;
		$previous_result->{is_last_of_day} = 1;
	}

	$result->{start_date_name} =
	  time::date_format( $result->{start_date}, $language );
	$result->{end_date_name} =
	  time::date_format( $result->{end_date}, $language );

	if ( $result->{start} =~ /(\d\d\:\d\d)\:\d\d/ ) {
		$result->{start_time_name} = $1;
		$result->{start_time}      = $1;
	}

	if ( $result->{end} =~ /(\d\d\:\d\d)\:\d\d/ ) {
		$result->{end_time_name} = $1;
		$result->{end_time}      = $1;
	}

	if ( defined $result->{weekday} ) {
		my $language = $config::config->{date}->{language} || 'en';

		#my $weekdays=time::get_weekdays();
		my $weekday_index = $time::weekday_index->{ $result->{weekday} . '' } || 0;
		$result->{weekday_name} =
		  $time::names->{$language}->{weekdays}->[$weekday_index];
		$result->{weekday_short_name} =
		  $time::names->{$language}->{weekdays_abbr}->[$weekday_index];
	}
	return $result;
}

sub add_recordings{
	my $dbh     = shift;
	my $config  = shift;
	my $request = shift;
	my $events  = shift;

#    print STDERR Dumper($results);
    return $events unless defined $events;

    my $params = $request->{params}->{checked};
    return $events unless defined $params;
    return $events unless defined $params->{recordings};

    my @ids=();
    my $eventsById={};
    #my $events = $results;
    
    for my $event (@$events){
        my $eventId = $event->{event_id};
        push @ids, $eventId;
        $eventsById->{$eventId} = $event;
    }


	my $qms        = join( ', ', (map { '?' }      @$events));
	my $bindValues = join( ', ', (map { $_->{event_id} } @$events));

	my $query = qq{
        select  *
        from    calcms_audio_recordings
        where   event_id in ($qms)
        order by created_at;
    };

	$dbh = db::connect($config) unless defined $dbh;
	my $recordings = db::get( $dbh, $query, $bindValues );
    #print STDERR Dumper($recordings);

    for my $entry (@$recordings){
        my $eventId = $entry->{event_id};
        my $event = $eventsById->{$eventId}; 
        push @{ $event->{recordings} }, $entry;
    }
    
    return $events;    
}

# if recordings is set in params, recordings date and path will be included
sub get_query {
	my $dbh     = shift;
	my $config  = shift;
	my $request = shift;

	my $params = $request->{params}->{checked};
	my $debug  = $config->{system}->{debug};

    $params->{recordings} = '' unless defined $params->{recordings};

	my $bind_values = [];
	my $where_cond  = [];
	my $order_cond  = '';
	my $limit_cond  = '';

	if ( $params->{event_id} ne '' ) {

		# conditions by event id
		push @$where_cond, 'e.id=?';
		$bind_values = [ $params->{event_id} ];

		#filter by published, default=1 to see published only, set published='all' to see all
		my $published = $params->{published} || 1;
		if ( ( $published eq '0' ) || ( $published eq '1' ) ) {
			push @$where_cond,  'published=?';
			push @$bind_values, $published;
		}

		my $draft = $params->{draft} || '0';
		if ( ( $draft eq '0' ) || ( $draft eq '1' ) ) {
			push @$where_cond,  'draft=?';
			push @$bind_values, $draft;
		}

	} else {

		# conditions by date
		my @date_conds = ();

		#date, today, tomorrow, yesterday
		my $date = '';
		$date = time::date_cond( $params->{date} ) if ( $params->{date} ne '' );

		my $from_date = '';
		$from_date = time::date_cond( $params->{from_date} )
		  if ( $params->{from_date} ne '' );

		my $till_date = '';
		$till_date = time::date_cond( $params->{till_date} )
		  if ( $params->{till_date} ne '' );

		my $from_time = '';
		$from_time = time::time_cond( $params->{from_time} )
		  if ( $params->{from_time} ne '' );

		my $till_time = '';
		$till_time = time::time_cond( $params->{till_time} )
		  if ( $params->{till_time} ne '' );

		my $date_range_include = $params->{date_range_include};

		#from_time is defined
		if ( ( $params->{from_date} ne '' ) && ( $params->{from_time} ne '' ) ) {
			my $datetime = time::datetime_cond( $from_date . 'T' . $from_time );
			if ( $datetime ne '' ) {
				if ( $date_range_include eq '1' ) {
					push @date_conds,   ' end > ? ';
					push @$bind_values, $datetime;
					$from_date = '';
				} else {
					push @date_conds,   ' start >= ? ';
					push @$bind_values, $datetime;
					$from_date = '';
				}
			}
		}

		#till_time is defined
		if ( ( $params->{till_date} ne '' ) && ( $params->{till_time} ne '' ) ) {
			my $datetime = time::datetime_cond( $till_date . 'T' . $till_time );
			if ( $datetime ne '' ) {
				push @date_conds,   ' start < ? ';
				push @$bind_values, $datetime;
				$till_date = '';
			}
		}

		#time is defined
		if (   ( defined $params->{time} )
			&& ( $params->{time} ne '' )
			&& ( $params->{time} ne 'now' )
			&& ( $params->{time} ne 'future' ) )
		{
			my $time = time::time_cond( $params->{time} );
			if ( $time ne '' ) {
				push @date_conds,   ' time(start) = ? ';
				push @$bind_values, $time;
			}
		}

		#event is not over
		if ( ( defined $params->{time} ) && ( $params->{time} eq 'now' ) ) {
			push @date_conds, qq{
                (
                ( unix_timestamp(end)   >  unix_timestamp(now() ) )
                and
                ( unix_timestamp(start) <= unix_timestamp(now() ) )
                )
            };

		} elsif ( ( defined $params->{time} ) && ( $params->{time} eq 'future' ) ) {
			push @date_conds, qq{
                (
                ( unix_timestamp(end)   >  unix_timestamp(now() ) )
                and
                ( unix_timestamp(end) - unix_timestamp(now() ) ) < 7*24*3600
                )
            };

		} elsif ( $date ne '' ) {
			if ( $date eq 'today' ) {
				my $date = time::get_event_date($config);
				if ( $date ne '' ) {
					push @date_conds,   ' ( start_date = ? ) ';
					push @$bind_values, $date;
				}

			} else {
				if ( $date ne '' ) {
					push @date_conds,   ' ( start_date = ? ) ';
					push @$bind_values, $date;
				}
			}
		} else {
			if ( $from_date ne '' ) {
				if ( $date_range_include eq '1' ) {

					# end is after start
					push @date_conds,   ' ( end_date >= ? )';
					push @$bind_values, $from_date;
				} else {
					push @date_conds,   ' ( start_date >= ? ) ';
					push @$bind_values, $from_date;
				}
			}

			if ( $till_date ne '' ) {
				if ( $date_range_include eq '1' ) {

					# start is before end
					push @date_conds,   ' ( start_date <= ? )';
					push @$bind_values, $till_date;
				} else {
					push @date_conds,   ' ( end_date <= ? ) ';
					push @$bind_values, $till_date;
				}
			}

			if ( $params->{weekday} ne '' ) {
				my $weekday = $params->{weekday};
				$weekday += 1;
				$weekday -= 7 if ( $weekday > 7 );
				push @date_conds,   ' (dayofweek(start_date)= ?) ';
				push @$bind_values, $weekday;
			}

			if ( $params->{archive} eq 'past' ) {
				my $date = time::get_event_date($config);
				if ( $date ne '' ) {
					push @date_conds,   ' ( start_date < ? ) ';
					push @$bind_values, $date;
				}

			} elsif ( $params->{archive} eq 'future' ) {
				my $date = time::get_event_date($config);
				if ( $date ne '' ) {
					push @date_conds,   ' ( start_date >= ? ) ';
					push @$bind_values, $date;
				}
			}

		}

		if (   ( defined $params->{time_of_day} )
			&& ( $params->{time_of_day} ne '' ) )
		{
			push @date_conds,   ' ( time_of_day = ? ) ';
			push @$bind_values, $params->{time_of_day};

		}

		my $date_cond = join " and ", @date_conds;
		push @$where_cond, $date_cond if ( $date_cond ne '' );
	}

	# location
	my $location_cond = '';
	if ( $params->{location} ne '' ) {
		my $location = ( split( /\,/, $params->{location} ) )[0];
		$location =~ s/[^a-zA-Z0-9]/%/g;
		$location =~ s/%{2,99}/%/g;
		if ( $location ne '' ) {
			$location_cond = ' location like ? ';
			push @$bind_values, $location;
		}
	}

	# exclude location
	my $exclude_location_cond = '';
	if ( $params->{no_exclude} ne '1' ) {
		if ( $params->{exclude_locations} ne '' ) {
			my @exclude_locations = split( /,/, $params->{exclude_locations} );
			$exclude_location_cond = 'location not in (' . join( ",", map { '?' } @exclude_locations ) . ')';
			for my $location (@exclude_locations) {
				$location =~ s/^\s+//g;
				$location =~ s/\s+$//g;
				push @$bind_values, $location;
			}
		}
	}

	# exclude project
	my $exclude_project_cond = '';
	if ( $params->{no_exclude} ne '1' ) {
		if ( $params->{exclude_projects} ne '' ) {
			my @exclude_projects = split( /,/, $params->{exclude_projects} );
			$exclude_project_cond = 'project not in (' . join( ",", map { '?' } @exclude_projects ) . ')';
			for my $project (@exclude_projects) {
				$project =~ s/^\s+//g;
				$project =~ s/\s+$//g;
				push @$bind_values, $project;
			}
		}
	}

	#filter for category
	my $category_cond = '';
	if ( $params->{category} ne '' ) {
		my $category = ( split( /\,/, $params->{category} ) )[0];
		$category =~ s/[^a-zA-Z0-9]/%/g;
		$category =~ s/%{2,99}/%/g;
		if ( $category ne '' ) {
			$category_cond = qq{
                id in(
                    select event_id from calcms_categories
                    where name like ?
                )
            };
		}
		push @$bind_values, $category;
	}

	my $series_name_cond = '';
	if (   ( defined $params->{series_name} )
		&& ( $params->{series_name} ne '' ) )
	{
		my $series_name = ( split( /\,/, $params->{series_name} ) )[0];
		$series_name =~ s/[^a-zA-Z0-9]/%/g;
		$series_name =~ s/%{2,99}/%/g;
		if ( $series_name ne '' ) {
			$series_name_cond = ' series_name like ? ';
			push @$bind_values, $series_name;
		}
	}

	#filter for tags
	my $tag_cond = '';
	if ( ( defined $params->{tag} ) && ( $params->{tag} ne '' ) ) {
		my @tags = ( split( /\,/, $params->{tag} ) );
		if ( scalar @tags > 0 ) {
			my $tags = join ",", ( map { '?' } @tags );
			for my $tag (@tags) {
				push @$bind_values, $tag;
			}
			$tag_cond = qq{
                id in(
                    select event_id from calcms_tags
                    where name in($tags)
                )
            };
		}
	}
	$tag_cond = '';

	my $title_cond = '';
	if ( ( defined $params->{title} ) && ( $params->{title} ne '' ) ) {
		my $title = ( split( /\,/, $params->{title} ) )[0];
		$title =~ s/[^a-zA-Z0-9]/%/g;
		$title =~ s/%{2,99}/%/g;
		$title =~ s/^\%//;
		$title =~ s/\%$//;
		$title = '%' . $title . '%';
		if ( $title ne '' ) {
			$title_cond = ' title like ? ';
			push @$bind_values, $title;
		}
	}

	my $search_cond = '';
	if ( ( defined $params->{search} ) && ( $params->{search} ne '' ) ) {
		my $search = lc $params->{search};
		$search =~ s/[^a-z0-9\_\.\-\:\!öäüßÖÄÜ \&]/%/;
		$search =~ s/\%+/\%/;
		$search =~ s/^[\%\s]+//;
		$search =~ s/[\%\s]+$//;
		if ( $search ne '' ) {
			$search = '%' . $search . '%';
			my @attr = ( 'title', 'series_name', 'excerpt', 'category', 'content', 'topic' );
			$search_cond = "(" . join( " or ", map { 'lower(' . $_ . ') like ?' } @attr ) . ")";
			for my $attr (@attr) {
				push @$bind_values, $search;
			}
		}
	}

	my $project_cond = '';

	#        if ($filter_by_project eq'1'){
	my $project = undef;    #$params->{default_project};
	$project = $params->{project}
	  if ( ( defined $params->{project} ) && ( $params->{project} ne '' ) );
	my $project_name = '';
	$project_name = $project->{name}
	  if ( ( defined $project )
		&& ( defined $project->{name} )
		&& ( $project->{name} ne '' ) );
	if ( ( $project_name ne '' ) && ( $project_name ne 'all' ) ) {
		$project_cond = '(project=?)';
		push @$bind_values, $project_name;
	}

	#        }

	#filter by published, default =1, set to 'all' to see all
	my $published_cond = '';
	my $published = $params->{published} || 1;
	if ( ( $published eq '0' ) || ( $published eq '1' ) ) {
		$published_cond = 'published=?';
		push @$bind_values, $published;
	}

	#filter by draft, default =1, set to 'all' to see all
	my $draft_cond = '';
	my $draft = $params->{draft} || '0';
	if ( ( $draft eq '0' ) || ( $draft eq '1' ) ) {
		$draft_cond = 'draft=?';
		push @$bind_values, $draft;
	}

	my $disable_event_sync_cond = '';
	my $disable_event_sync = $params->{disable_event_sync} || '';
	if ( ( $disable_event_sync eq '0' ) || ( $disable_event_sync eq '1' ) ) {
		$disable_event_sync_cond = 'disable_event_sync=?';
		push @$bind_values, $disable_event_sync;
	}

	#print STDERR $disable_event_sync_cond." ".$bind_values->[-1]."\n";

	#combine date, location, category, series_name, tag, search and project

	push @$where_cond, $location_cond if ( $location_cond =~ /\S/ );
	push @$where_cond, $exclude_location_cond
	  if ( $exclude_location_cond =~ /\S/ );
	push @$where_cond, $exclude_project_cond
	  if ( $exclude_project_cond =~ /\S/ );
	push @$where_cond, $category_cond    if ( $category_cond =~ /\S/ );
	push @$where_cond, $series_name_cond if ( $series_name_cond =~ /\S/ );
	push @$where_cond, $tag_cond         if ( $tag_cond =~ /\S/ );
	push @$where_cond, $title_cond       if ( $title_cond =~ /\S/ );
	push @$where_cond, $search_cond      if ( $search_cond =~ /\S/ );
	push @$where_cond, $project_cond     if ( $project_cond =~ /\S/ );
	push @$where_cond, $published_cond   if ( $published_cond =~ /\S/ );
	push @$where_cond, $draft_cond       if ( $draft_cond =~ /\S/ );
	push @$where_cond, $disable_event_sync_cond
	  if ( $disable_event_sync_cond ne '' );

	#print STDERR Dumper($where_cond);

	#order is forced
	if ( $params->{order} eq 'asc' ) {
		$order_cond = 'order by start';
	} elsif ( $params->{order} eq 'desc' ) {
		$order_cond = 'order by start desc';
	} else {

		#derivate order from archive flag
		if ( $params->{archive} eq 'past' ) {
			$order_cond = 'order by start desc';
		} else {
			$order_cond = 'order by start';
		}
	}

	if ( ( defined $params->{limit} ne '' ) && ( $params->{limit} ne '' ) ) {
		$limit_cond = 'limit ' . $params->{limit};
	}

	my $query = qq{
        select
             date(e.start)        start_date
            ,date(e.end)          end_date
            ,weekday(e.start)     weekday
            ,weekofyear(e.start)  week_of_year
            ,dayofyear(e.start)   day_of_year
            ,e.start_date         day
            ,e.id                 event_id
            ,e.start
            ,e.end
            ,e.time_of_day
            ,e.program
            ,e.series_name
            ,e.title
            ,e.modified_at
            ,e.created_at
            ,e.modified_by
            ,e.comment_count
            ,e.image
            ,e.reference
            ,e.recurrence
            ,e.recurrence_count
            ,e.podcast_url
            ,e.archive_url
            ,e.media_url
            ,e.status
            ,e.location
            ,e.project
            ,e.user_title
            ,e.user_excerpt
            ,e.published
            ,e.draft
            ,e.playout
            ,e.archived
            ,e.rerun
            ,e.live
            ,e.disable_event_sync
            ,e.episode
    };
	my $template = $params->{template} || '';

	$query .= ',e.excerpt' unless ( $template =~ /menu/ );

	#    $query.=',e.project'                 unless ($template=~/menu/ || $template=~/list/);

	my $get = $params->{get} || '';
	unless ( $get eq 'no_content' ) {
		if ( $template =~ /\.html/ ) {
			unless ( $template =~ /menu/ || $template =~ /list/ ) {
				$query .= ', e.content, e.topic, e.html_content, e.html_topic';

				#$query.=',html_content content, html_topic topic' ;
			}
		} else {
			unless ( $template =~ /menu/ || $template =~ /list/ ) {
				$query .= ', e.content, e.topic, e.html_content, e.html_topic';
			}
		}
	}

	# add project id and series id
	if ( ( $params->{project_id} ne '' ) || ( $params->{studio_id} ne '' ) ) {
		if ( $params->{project_id} ne '' ) {
			push @$where_cond,  'se.project_id=?';
			push @$bind_values, $params->{project_id};
			$query .= ', se.project_id';
		}
		if ( $params->{studio_id} ne '' ) {
			push @$where_cond,  'se.studio_id=?';
			push @$bind_values, $params->{studio_id};
			$query .= ', se.studio_id';
		}
		#push @$where_cond, 'se.event_id=e.id';
	}

	# add recordings field and conditions
	if ($params->{recordings} eq '1' ) {
		$query .= ', ar.path';
		$query .= ', ar.size';
		$query .= ', ar.created_by uploaded_by';
		$query .= ', ar.modified_at uploaded_at';
		#push @$where_cond,  'e.id=ar.event_id';
	}
	
	$query .= "\n from";
	
	# add tables
	if ( ( $params->{project_id} ne '' ) || ( $params->{studio_id} ne '' ) ) {
	    # prepent series_events
		$query .= "\n calcms_series_events se inner join calcms_events e on se.event_id=e.id";
	}else{
		$query .= "\n calcms_events e";
	}

	# add recordings table
	if ( $params->{recordings} eq '1' ) {
		$query .= "\n left join calcms_audio_recordings ar on e.id=ar.event_id";
	}

	if ( scalar @$where_cond > 0 ) {
		$query .= "\nwhere " . join( ' and ', @$where_cond );
	}

	$query .= "\n" . $order_cond if ( $order_cond ne '' );
	$query .= "\n" . $limit_cond if ( $limit_cond ne '' );

	#print STDERR Dumper($query).Dumper($bind_values)."\n";

	return ( \$query, $bind_values );
}

sub render {

	#    my $response    = $_[0];
	my $config      = $_[1];
	my $request     = $_[2];
	my $results     = $_[3];
	my $root_params = $_[4];

	my $params = $request->{params}->{checked};
	if ( ref($root_params) eq 'HASH' ) {
		for my $param ( keys %$root_params ) {
			$params->{$param} = $root_params->{$param};
		}
	}
	my $debug = $config->{system}->{debug};

	my %template_parameters = %$params;
	my $template_parameters = \%template_parameters;
	$template_parameters->{events}       = $results;
	$template_parameters->{debug}        = $debug;
	$template_parameters->{server_cache} = $config->{cache}->{server_cache}
	  if ( $config->{cache}->{server_cache} );
	$template_parameters->{use_client_cache} = $config->{cache}->{use_client_cache}
	  if ( $config->{cache}->{use_client_cache} );

	if ( scalar @$results > 0 ) {
		my $result = $results->[0];
		$template_parameters->{event_id}      = $result->{event_id};
		$template_parameters->{event_dtstart} = $result->{dtstart};
	}

	#    $template_parameters->{print}            =1 if ($params->{print} eq '1');
	$template_parameters->{base_url}       = $config->{locations}->{base_url};
	$template_parameters->{base_domain}    = $config->{locations}->{base_domain};
	$template_parameters->{cache_base_url} = $config->{cache}->{base_url};
	$template_parameters->{modified_at}    = time::time_to_datetime( time() );
	if (   ( defined $params->{template} )
		&& ( $params->{template} =~ /(\.xml)/ ) )
	{
		$template_parameters->{modified_at_datetime_utc} =
		  time::datetime_to_utc_datetime( $template_parameters->{modified_at}, $config->{date}->{time_zone} );
	}

	#$template_parameters->{tags}        = $tags;

	if ( @$results == 0 ) {
		if (   ( $params->{search} ne '' )
			|| ( $params->{category} ne '' )
			|| ( $params->{series_name} ne '' ) )
		{
			$template_parameters->{no_search_result} = '1';
		} else {
			$template_parameters->{no_result} = '1';
		}
	} else {
		if ( ( !defined $params->{event_id} ) || ( $params->{event_id} eq '' ) ) {
			$template_parameters->{event_count}   = @$results . '';
			$template_parameters->{first_of_list} = $results->[0]->{event_id};
		}
		my $start = $results->[0]->{start_datetime} || '';
		if ( $start =~ /(\d{4}\-\d{2})/ ) {
			$template_parameters->{month} = $1;
		}
	}

	my $time_diff = time::utc_offset( $config->{date}->{time_zone} );
	$time_diff =~ s/(\d\d)(\d\d)/$1\:$2/g;
	$template_parameters->{time_zone}  = $config->{date}->{time_zone};
	$template_parameters->{utc_offset} = $time_diff;

	if ( $params->{template} =~ /\.atom\.xml/ ) {
		$template_parameters->{modified_at} =~ s/ /T/gi;
		$template_parameters->{modified_at} .= $time_diff;
	} elsif ( $params->{template} =~ /\.rss\.xml/ ) {
		$template_parameters->{modified_at} =
		  time::datetime_to_rfc822( $template_parameters->{modified_at} );
	} elsif ( $params->{template} =~ /\.txt/ ) {
		$template_parameters->{modified_at_utc} =
		  time::datetime_to_utc( $template_parameters->{modified_at}, $config->{date}->{time_zone} );
	}

	my $project = $params->{default_project};
	foreach my $key ( keys %$project ) {
		$template_parameters->{ 'project_' . $key } = $project->{$key};
	}
	$template_parameters->{ 'project_' . $project->{name} } = 1
	  if ( $project->{name} ne '' );

	$template_parameters->{controllers} = $config->{controllers},

	  #    use Data::Dumper;print STDERR Dumper($template_parameters)."\n";
	  template::process( $_[0], $params->{template}, $template_parameters );

	return $_[0];
}

sub get_running_event_id {
	my $dbh = shift;

	my $query = qq{
        select id event_id, start, title
        from calcms_events
        where
    (
        ( unix_timestamp(start) <= unix_timestamp(now() ) )
        and
        ( unix_timestamp(end) > unix_timestamp(now() ) )
        and
        ( unix_timestamp(end) - unix_timestamp(now() ) ) < 24*3600
    )

        order by start
        limit 1
    };

	my $running_events = db::get( $dbh, $query );
	my @running_events = @$running_events;

	return $running_events->[0]->{event_id} if ( scalar @running_events > 0 );
	return 0;
}

# add filters to query
sub setDefaultEventConditions {
	my $config      = shift;
	my $conditions  = $_[0];
	my $bind_values = $_[1];

	# exclude projects
	if (   ( defined $config->{filter} )
		&& ( defined $config->{filter}->{exclude_projects} ) )
	{
		my @exclude_projects =
		  split( /,/, $config->{filter}->{exclude_projects} );
		push @$conditions, 'project not in (' . join( ",", map { '?' } @exclude_projects ) . ')';
		for my $project (@exclude_projects) {
			push @$bind_values, $project;
		}
	}

	# exclude locations
	if (   ( defined $config->{filter} )
		&& ( defined $config->{filter}->{exclude_locations} ) )
	{
		my @exclude_locations =
		  split( /,/, $config->{filter}->{exclude_locations} );
		push @$conditions, 'location not in (' . join( ",", map { '?' } @exclude_locations ) . ')';
		for my $location (@exclude_locations) {
			push @$bind_values, $location;
		}
	}

}

sub getEventById {
	my $dbh      = shift;
	my $config   = shift;
	my $event_id = shift;

	$dbh = db::connect($config) unless defined $dbh;

	my $conditions  = [];
	my $bind_values = [];

	push @$conditions,  "id=?";
	push @$bind_values, $event_id;

	setDefaultEventConditions( $config, $conditions, $bind_values );
	$conditions = join( ' and ', @$conditions );

	my $query = qq{
        select  *
        from    calcms_events
        where   $conditions
    };

	my $events = db::get( $dbh, $query, $bind_values );
	return $events;
}

sub get_next_event_of_series {
	my $dbh      = shift;
	my $config   = shift;
	my $event_id = shift;

	$dbh = db::connect($config) unless defined $dbh;

	my $events = getEventById( $dbh, $config, $event_id );
	return undef unless @$events == 1;
	my $event = $events->[0];

	my $conditions  = [];
	my $bind_values = [];

	push @$conditions,  "start>?";
	push @$bind_values, $event->{start};

	push @$conditions,  "series_name=?";
	push @$bind_values, $event->{series_name};

	setDefaultEventConditions( $config, $conditions, $bind_values );
	$conditions = join( ' and ', @$conditions );

	my $query = qq{
        select  id 
        from    calcms_events
        where   $conditions
        order by start
        limit 1
    };

	$events = db::get( $dbh, $query, $bind_values );
	return undef unless @$events == 1;

	return $events->[0]->{id};
}

sub get_previous_event_of_series {
	my $dbh      = shift;
	my $config   = shift;
	my $event_id = shift;

	$dbh = db::connect($config) unless defined $dbh;

	my $events = getEventById( $dbh, $config, $event_id );
	return undef unless @$events == 1;
	my $event = $events->[0];

	my $conditions  = [];
	my $bind_values = [];

	push @$conditions,  "start<?";
	push @$bind_values, $event->{start};

	push @$conditions,  "series_name=?";
	push @$bind_values, $event->{series_name};

	setDefaultEventConditions( $config, $conditions, $bind_values );
	$conditions = join( ' and ', @$conditions );

	my $query = qq{
        select id from calcms_events
        where     $conditions
        order by  start desc
        limit 1
    };
	$events = db::get( $dbh, $query, $bind_values );

	return undef unless @$events == 1;
	return $events->[0]->{id};
}

sub get_by_date_range {
	my $dbh        = shift;
	my $config     = shift;
	my $start_date = shift;
	my $end_date   = shift;

	my $conditions = [];
	push @$conditions, 'start_date between ? and ?';
	my $bind_values = [ $start_date, $end_date ];

	setDefaultEventConditions( $config, $conditions, $bind_values );

	$conditions = join( ' and ', @$conditions );

	my $query = qq{
        select   start_date 
        from     calcms_events 
        where    $conditions
        group by start_date
    };

	my $events = db::get( $dbh, $query, $bind_values );

	return $events;
}

sub get_by_image {
	my $dbh      = shift;
	my $config   = shift;
	my $filename = shift;

	#$filename=$dbh->quote('%'.$filename.'%');

	#$filename='%'.$filename.'%';
	my $query = qq{
        select * from calcms_events
        where content like ?
        order by start desc
        limit 1
    };
	my $bind_values = [ '%' . $filename . '%' ];

	my $events = db::get( $dbh, $query, $bind_values );

	#    print STDERR Dumper($events);
	return undef if ( @$events == 0 );
	return $events->[0];
}

sub delete {
	return;
	my $request  = shift;
	my $config   = shift;
	my $event_id = shift;

	my $params = $request->{params}->{checked};
	my $debug  = $config->{system}->{debug};

	my $dbh = db::connect($config);

	my $query = 'delete from calcms_events where id=?';
	db::put( $dbh, $query, [$event_id] );

	$query = 'delete from calcms_categories where id=?';
	db::put( $dbh, $query, [$event_id] );

	$query = 'delete from calcms_tags where id=?';
	db::put( $dbh, $query, [$event_id] );

	$query = 'delete from calcms_series_events where event_id=?';
	db::put( $dbh, $query, [$event_id] );

}

#TODO: add location to cache map
sub configure_cache {
	my $config = shift;
	my $debug  = $config->{system}->{debug};

	my $date_pattern = $cache::date_pattern;
	my $controllers  = $config->{controllers};

	cache::init();
	cache::add_map( '', 'index.html' );

	my $name      = '';
	my $extension = '';
	my $templates = $config->{templates}->{events};

	for my $template (@$templates) {
		if ( $template =~ /^(.+)\.([^\.]+)$/ ) {
			$name      = $1;
			$extension = $2;
		}
		cache::add_map( 'template=' . $template,                 $controllers->{events} . '/' . $name . '.' . $extension );
		cache::add_map( 'template=' . $template . '&date=today', $controllers->{events} . '/' . $template . '_today.' . $extension );
		cache::add_map( 'template=' . $template . '&date=' . $date_pattern,
			$controllers->{events} . '/' . $name . '_date_$1-$2-$3.' . $extension );
		cache::add_map( 'template=' . $template . '&time=now', $controllers->{events} . '/' . $template . '_now.html' );
		cache::add_map( 'template=' . $template . '&time=now&limit=(\d+)',
			$controllers->{events} . '/' . $name . '_now_limit_$1.' . $extension );
		cache::add_map(
			'template=' . $template . '&from_date=' . $date_pattern . '&till_date=' . $date_pattern,
			$controllers->{events} . '/' . $name . '_from_$1-$2-$3_till_$4_$5_$6.' . $extension
		);
		cache::add_map(
			'template=' . $template . '&from_date=' . $date_pattern . '&till_date=' . $date_pattern . '&weekday=(\d)',
			$controllers->{events} . '/' . $template . '_from_$1-$2-$3_till_$4_$5_$6_weekday_$7.' . $extension
		);
		cache::add_map(
			'template=' . $template . '&from_date=' . $date_pattern . '&till_date=' . $date_pattern . '&limit=(\d)',
			$controllers->{events} . '/' . $template . '_from_$1-$2-$3_till_$4_$5_$6_limit_$7.' . $extension
		);
		cache::add_map( 'template=' . $template . '&weekday=(\d)',   $controllers->{events} . '/' . $name . '_weekday_$1.' . $extension );
		cache::add_map( 'template=' . $template . '&event_id=(\d+)', $controllers->{event} . '/' . $name . '_page_$1.' . $extension );
	}
}

sub get_duration {
	my $config   = shift;
	my $event    = shift;
	my $timezone = $config->{date}->{time_zone};
	my $start    = time::get_datetime( $event->{start}, $timezone );
	my $end      = time::get_datetime( $event->{end},   $timezone );
	#my $seconds  = $end->subtract($start)->in_units("minutes");
	#return $seconds;
	return undef unless defined $start;
	return undef unless defined $end;
	my $duration = $end->epoch() - $start->epoch();
	#print STDERR "duration=$duration, end=".$end->datetime()." start=".$start->datetime()."\n";
	return $duration / 60;
}

sub check_params {
	my $config = shift;
	my $params = shift;

	#define running at
	my $running_at = $params->{running_at} || '';
	if ( ( defined $running_at ) && ( $running_at ne '' ) ) {
		my $run_date = time::check_date($running_at);
		my $run_time = time::check_time($running_at);
		if ( ( $run_date ne '' ) && ( $run_time ne '' ) ) {
			$params->{till_date} = $run_date;
			$params->{till_time} = $run_time;
			$params->{order}     = 'asc';
			$params->{limit}     = 1;
			$params->{archive}   = 'all';
		}
	}

	#set time
	my $time      = time::check_time( $params->{time} );
	my $from_time = time::check_time( $params->{from_time} );
	my $till_time = time::check_time( $params->{till_time} );

	#set date
	my $date      = '';
	my $from_date = time::check_date( $params->{from_date} );
	my $till_date = time::check_date( $params->{till_date} );
	if ( ( $from_date eq '' ) && ( $till_date eq '' ) ) {
		$date = time::check_date( $params->{date} );
	}

	#set date interval (including)
	my $date_range_include = 0;
	$date_range_include = 1
	  if ( defined $params->{date_range_include} )
	  && ( $params->{date_range_include} eq '1' );

	my $order = '';
	if ( defined $params->{order} ) {
		$order = 'desc' if ( $params->{order} eq 'desc' );
		$order = 'asc'  if ( $params->{order} eq 'asc' );
	}

	my $weekday = $params->{weekday} || '';

	if ( ( defined $weekday ) && ( $weekday ne '' ) ) {
		if ( $weekday =~ /\d/ ) {
			$weekday = int($weekday);
			log::error( $config, 'invalid weekday' )
			  if ( $weekday < 1 || $weekday > 7 );
		} else {
			log::error( $config, 'invalid weekday' );
		}
	}

	my $time_of_day = $params->{time_of_day} || '';
	my $found = 0;
	if ( defined $time_of_day ) {
		for my $key ( 'night', 'morning', 'noon', 'afternoon', 'evening' ) {
			$found = 1 if ( $key eq $time_of_day );
		}
		log::error( $config, 'invalid time_of_day' )
		  if ( ( $time_of_day ne '' ) && ( $found == 0 ) );
	}

	my $tag = $params->{tag} || '';
	if ( ( defined $tag ) && ( $tag ne '' ) ) {
		log::error( $config, "invalid tag" ) if ( $tag =~ /\s/ );
		log::error( $config, "invalid tag" ) if ( $tag =~ /\;/ );
		$tag =~ s/\'//gi;
	}

	my $category = $params->{category} || '';
	if ( ( defined $category ) && ( $category ne '' ) ) {
		log::error( $config, "invalid category" ) if ( $category =~ /\;/ );
		$category =~ s/^\s+//gi;
		$category =~ s/\s+$//gi;
		$category =~ s/\'//gi;
	}

	my $series_name = $params->{series_name} || '';
	if ( ( defined $series_name ) && ( $series_name ne '' ) ) {
		log::error( $config, "invalid series_name" )
		  if ( $series_name =~ /\;/ );
		$series_name =~ s/^\s+//gi;
		$series_name =~ s/\s+$//gi;
		$series_name =~ s/\'//gi;
	}

	my $title = $params->{title} || '';
	if ( ( defined $title ) && ( $title ne '' ) ) {
		log::error( $config, "invalid title" ) if ( $title =~ /\;/ );
		$title =~ s/^\s+//gi;
		$title =~ s/\s+$//gi;
		$title =~ s/\'//gi;
	}

	my $location = $params->{location} || '';
	if ( ( defined $location ) && ( $location ne '' ) ) {
		log::error( $config, "invalid location" ) if ( $location =~ /\;/ );
		$location =~ s/^\s+//gi;
		$location =~ s/\s+$//gi;
		$location =~ s/\'//gi;
	}

	#if no location is set, use exclude location filter from default config
	my $exclude_locations = '';
	if (   ( $location eq '' )
		&& ( defined $config->{filter} )
		&& ( defined $config->{filter}->{exclude_locations} ) )
	{
		$exclude_locations = $config->{filter}->{exclude_locations} || '';
		$exclude_locations =~ s/\s+/ /g;
	}

	my $exclude_projects = '';
	if (   ( defined $config->{filter} )
		&& ( defined $config->{filter}->{exclude_projects} ) )
	{
		$exclude_projects = $config->{filter}->{exclude_projects} || '';
		$exclude_projects =~ s/\s+/ /g;
	}

	#disable exclude filter by 'no_exlude=1'
	my $no_exclude = '';
	$no_exclude = '1'
	  if ( ( defined $params->{no_exclude} )
		&& ( $params->{no_exclude} eq '1' ) );

	#show future events by default
	my $archive = 'future';
	if ( defined $params->{archive} ) {
		$archive = 'all'    if ( $params->{archive} eq 'all' );
		$archive = 'past'   if ( $params->{archive} eq 'gone' );
		$archive = 'future' if ( $params->{archive} eq 'coming' );
	}

	my $disable_event_sync = '';
	if (   ( defined $params->{disable_event_sync} )
		&& ( $params->{disable_event_sync} =~ /([01])/ ) )
	{
		$disable_event_sync = $1;
	}

	#show all on defined timespans
	if ( ( $from_date ne '' ) && ( $till_date ne '' ) ) {
		$archive = 'all';
	}

	my $event_id = $params->{event_id} || '';
	if ( ( defined $event_id ) && ( $event_id ne '' ) ) {
		if ( $event_id =~ /(\d+)/ ) {
			$event_id = $1;
		} else {
			log::error( $config, "invalid event_id" );
		}
	}

	my $get = 'all';
	$get = 'no_content'
	  if ( ( defined $params->{get} ) && ( $params->{get} eq 'no_content' ) );

	my $search = $params->{search} || '';
	if ( ( defined $search ) && ( $search ne '' ) ) {
		$search = substr( $search, 0, 100 );
		$search =~ s/^\s+//gi;
		$search =~ s/\s+$//gi;
	}

	#print STDERR $params->{template}."\n";
	my $template = '.html';
	if ( $params->{template} eq 'no' ) {
		$template = 'no';
	} else {
		$template = template::check( $params->{template}, 'event_list.html' );
	}

	my $limit_config = $config->{permissions}->{result_limit} || 100;
	my $limit = $params->{limit} || $limit_config;
	log::error( $config, 'invalid limit!' ) if ( $limit =~ /\D/ );
	$limit = $limit_config if ( $limit_config < $limit );

	#read project from configuration file
	my $project_name = $config->{project} || '';
	log::error( $config, 'no default project configured' )
	  if ( $project_name eq '' );

	#get default project
	my $default_project = undef;
	my $projects = project::get( $config, { name => $project_name } );
	log::error( $config, "no configuration found for project '$project_name'" )
	  unless ( @$projects == 1 );
	$default_project = $projects->[0];

	# get project from parameter (by name)
	my $project = '';
	if (   ( defined $params->{project} )
		&& ( $params->{project} =~ /\w+/ )
		&& ( $params->{project} ne 'all' ) )
	{
		my $project_name = $params->{project};
		my $projects = project::get( $config, { name => $project_name } );
		log::error( $config, 'invalid project ' . $project_name )
		  unless @$projects == 1;
		$project = $projects->[0];
	}

	$project_name = $params->{project_name} || '';
	my $studio_name = $params->{studio_name} || '';

	my $project_id = $params->{project_id} || '';
	my $studio_id  = $params->{studio_id}  || '';

	my $debug = $params->{debug} || '';
	if ( $debug =~ /([a-z\_\,]+)/ ) {
		$debug = $1;
	}

	my $json_callback = $params->{json_callback} || '';
	if ( $json_callback ne '' ) {
		$json_callback =~ s/[^a-zA-Z0-9\_]//g;
	}

	# use relative links
	my $extern = 0;
	$extern = 1 if ( defined $params->{extern} ) && ( $params->{extern} eq '1' );
	
	my $recordings = 0;
	$recordings = 1 if ( defined $params->{recordings} ) && ( $params->{recordings} eq '1' );

	my $checked = {
		date               => $date,
		time               => $time,
		time_of_day        => $time_of_day,
		from_date          => $from_date,
		till_date          => $till_date,
		date_range_include => $date_range_include,
		from_time          => $from_time,
		till_time          => $till_time,
		weekday            => $weekday,
		limit              => $limit,
		template           => $template,
		location           => $location,
		category           => $category,
		series_name        => $series_name,
		tag                => $tag,
		title              => $title,
		event_id           => $event_id,
		search             => $search,
		debug              => $debug,
		archive            => $archive,
		order              => $order,
		project            => $project,
		default_project    => $default_project,
		project_name       => $project_name,
		project_id         => $project_id,
		studio_name        => $studio_name,
		studio_id          => $studio_id,
		json_callback      => $json_callback,
		get                => $get,
		exclude_locations  => $exclude_locations,
		exclude_projects   => $exclude_projects,
		no_exclude         => $no_exclude,
		disable_event_sync => $disable_event_sync,
		extern             => $extern,
		recordings         => $recordings,
	};

	#print STDERR Dumper($checked);
	return $checked;
}

sub get_keys {
	my $event = shift;

	my $program                = $event->{program}                || '';
	my $series_name            = $event->{series_name}            || '';
	my $title                  = $event->{title}                  || '';
	my $user_title             = $event->{user_title}             || '';
	my $episode                = $event->{episode}                || '';
	my $recurrence_count_alpha = $event->{recurrence_count_alpha} || '';

	my $skey = '';
	$skey .= $series_name if $series_name ne '';
	$skey .= ' - '
	  if ( $series_name ne '' )
	  && ( ( $title ne '' ) || ( $user_title ne '' ) );

	my $tkey = '';
	$tkey = $title if $title ne '';
	$tkey .= ': ' if ( $title ne '' ) && ( $user_title ne '' );
	$tkey .= $user_title             if $user_title ne '';
	$tkey .= ' #' . $episode         if $episode ne '';
	$tkey .= $recurrence_count_alpha if $recurrence_count_alpha ne '';

	my $pkey = '';
	$pkey = ' (' . $program . ')' if $program ne '';

	return {
		key                             => $skey . $tkey . $pkey,
		full_title                      => $skey . $tkey . $pkey,
		full_title_no_series            => $tkey . $pkey,
		full_title_no_program           => $skey . $tkey,
		full_title_no_program_no_series => $tkey
	};
}

#do not delete last line!
1;

