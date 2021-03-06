#!/bin/perl

use CGI;
#use CGI::Carp qw(warningsToBrowser fatalsToBrowser); 
use CGI::Session qw(-ip-match);
use CGI::Cookie;
#$CGI::Session::IP_MATCH=1;

package auth; 

use warnings "all";
use strict;

use Data::Dumper;
use Authen::Passphrase::BlowfishCrypt;
use time;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(get_user login logout crypt_password);
our %EXPORT_TAGS = ( 'all'  => [ @EXPORT_OK ] );


my $defaultExpiration=60;
my $tmp_dir='/var/tmp/';
my $debug=0;

sub debug;

sub get_user{
	my $cgi=shift;
	my $config=shift;

	my %parms=$cgi->Vars();
	my $parms=\%parms;

	debug("get_user")if ($debug);

    # login or logout on action
	if (defined $parms->{action}){
		if ($parms->{action} eq 'login'){
			my $user=login($cgi, $config, $parms->{user}, $parms->{password});
			$cgi->delete('user','password','uri','action');
			return $user;
		}elsif($parms->{action} eq 'logout'){
			logout($cgi);
			$cgi->delete('user','password','uri','action');
			return undef;
		}
	}

    # read session id from cookie
	my $session_id=read_cookie($cgi);

    # login if no cookie found
	return show_login_form($parms->{user}, 'Please login') unless defined $session_id;

    # read session
	my $session=read_session($session_id);

    # login if user not found
	return show_login_form($parms->{user}, 'unknown User') unless defined $session;

	$parms->{user}    = $session->{user};
	$parms->{expires} = $session->{expires};
    debug($parms->{expires});
	return $session->{user}, $session->{expires};
}

sub crypt_password{
	my $password=shift;

	my $ppr = Authen::Passphrase::BlowfishCrypt->new(
		cost => 8, 
		salt_random => 1,
		passphrase => $password
	);
	return{
		salt 	=> $ppr->salt_base64,
		crypt	=> $ppr->as_crypt
	};
}

sub login{
	my $cgi=shift;
	my $config=shift;
	my $user=shift;
	my $password=shift;
	debug("login")if ($debug);
	
	#print STDERR "login $user $password\n";
	my $result = authenticate($config, $user, $password);
    #print STDERR Dumper($result);

    return show_login_form($user,'Could not authenticate you') unless defined $result;
    return unless defined $result->{login}eq '1';

    my $timeout=$result->{timeout} || $defaultExpiration;
    $timeout='+'.$timeout.'m';

	my $session_id=create_session($user, $password, $timeout);
	return $user if(create_cookie($cgi, $session_id, $timeout));
	return undef;
}

sub logout{
	my $cgi=shift;
	my $session_id=read_cookie($cgi);
	debug("logout")if ($debug);
	unless(delete_session($session_id)){
		return show_login_form('Cant delete session', 'logged out');
	};
	unless(delete_cookie($cgi)){
		return show_login_form('Cant remove cookie', 'logged out');
	}
	my $uri=$ENV{HTTP_REFERER}||'';
	$uri=~s/action=logout//g;
	print $cgi->redirect($uri);
#	return show_login_form('', 'logged out');
}

#read and write data from browser, http://perldoc.perl.org/CGI/Cookie.html
sub create_cookie{
	my $cgi=shift;
	my $session_id=shift;
	my $timeout=shift;
	#debug("create_cookie")if ($debug);

	my $cookie = CGI::Cookie->new(
		-name 		=> 'sessionID',
		-value 		=> $session_id,
		-expires	=> $timeout,
#		-domain  =>  '.capricorn.com',
#		-path    =>  '/agenda/admin/',
		-secure  =>  1
	);
	print "Set-Cookie: ",$cookie->as_string,"\n";
	print STDERR "#Set-Cookie: ",$cookie->as_string,"\n";
#	print $cgi->header( -cookie => $cookie );
	return 1;
}

sub read_cookie{
	my $cgi=shift;

	debug("read_cookie")if ($debug);
	my %cookie = CGI::Cookie->fetch;
	debug("cookies: ".Dumper(\%cookie))if ($debug);
	my $cookie=$cookie{'sessionID'};
	debug("cookie: ".$cookie)if ($debug);
	return undef unless (defined $cookie);
	my $session_id= $cookie->value || undef;
	debug("sid: ".$session_id)if ($debug);
	return $session_id;
	#return $cgi->cookie('sessionID') || undef; 
};

sub delete_cookie{
	my $cgi=shift;

	debug("delete_cookie")if ($debug);
	my $cookie = $cgi->cookie(
	  -name 	=> 'sessionID',
	  -value 	=> '',
	  -expires 	=> '+1s'
	);
	print $cgi->header( -cookie => $cookie );
	return 1;
}

#read and write server-side session data
sub create_session{
	my $user=shift;
	my $password=shift;
	my $expiration=shift;

	debug("create_session")if ($debug);
	my $session = new CGI::Session(undef, undef, {Directory=>$tmp_dir});
	$session->expire($expiration);
	$session->param("user",  $user);
	$session->param("pid",  $$);
#	$session->param("password", $password);
	return $session->id();
}

sub read_session{
	my $session_id=shift;

	debug("read_session")if $debug;
	return undef unless(defined $session_id);

	debug("read_session2")if $debug;
	my $session = new CGI::Session(undef, $session_id, {Directory=>$tmp_dir});
	return undef unless defined $session;

	debug("read_session3")if $debug;
	my $user = $session->param("user") || undef;
	return undef unless defined $user;
    my $expires = time::time_to_datetime($session->param("_SESSION_ATIME")+$session->param("_SESSION_ETIME"));
	return {
        user => $user,
        expires => $expires
    }
}

sub delete_session{
	my $session_id=shift;

	debug("delete_session")if ($debug);
	return undef unless(defined $session_id);
	my $session = new CGI::Session(undef, $session_id, {Directory=>$tmp_dir});
	$session->delete();
	return 1;
}


#check user authentication
sub authenticate{
	my $config=shift;
	my $user=shift;
	my $password=shift;

	$config->{access}->{write}=0;
	my $dbh = db::connect($config);
	my $query = qq{
		select	*
		from 	calcms_users
		where 	name=?
	};
	my $bind_values = [$user];
	#print STDERR "query:".Dumper($query).Dumper($bind_values);

	my $users = db::get($dbh,$query,$bind_values);
	#print STDERR "result:".Dumper($users);
	
	if (scalar(@$users) != 1){
		print STDERR "auth: did not find user '$user'\n";
		return undef;
	}
	#print STDERR Dumper($users);

	my $salt=$users->[0]->{salt};
	my $ppr = Authen::Passphrase::BlowfishCrypt->from_crypt(
        $users->[0]->{pass},
        $users->[0]->{salt}
	);

	return undef unless $ppr->match($password);
    if($users->[0]->{disabled} == 1){
		print STDERR "user '$user' is disabled\n";
        return undef;
    }

    my $timeout = $users->[0]->{session_timeout} || 120;
    $timeout    =10    if $timeout < 10;
    $timeout    =12*60 if $timeout > 12*60;

    return {
        timeout => $timeout,
        login   => 1
    }
}

sub show_login_form{
	my $user=shift||'';
	my $uri=$ENV{HTTP_REFERER}||'';
	my $message=shift||'';
	debug("show_login_form")if ($debug);
	print qq{Content-type:text/html

<!DOCTYPE HTML>        
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<style type="text/css">
    html,body{
        height: 100%;
        font-family:helvetica,arial,sans-serif;
    }

    body{
        display: table; 
        margin: 0 auto;
    }

    input, .row, .field{
        padding:0.5em;
    }

    .container{
        height: 100%;
        display: table-cell;   
        vertical-align: middle;    
    }

	#login_form{
		background:#ddd;
        box-shadow: 1em 1em 1em #888;
		margin:1em;
		padding:1em;
        text-align:center;
	}

	#login_form .field{
		width:8em;
		float:left;
	}

	#login_form .message{
		background:#ccc;
		text-align:left;
		font-weight:bold;
        padding:1em;
        margin:-1em;
        margin-bottom:0;
	}
</style>
</head>
<body>

<div class="container">
    <div id="login_form">
	    <div class="message">$message</div><br/>
	    <form method="post">
            <div class="row">
		        <div class="field">user</div>
		        <input name="user" value="$user"><br/>
            </div>
            <div class="row">
		        <div class="field">password</div>
		        <input type="password" name="password"><br/>
            </div>
            <div class="row">
		        <input type="submit" name="action" value="login">
		        <input type="submit" name="action" value="logout">
            </div>
		    <input type="hidden" name="uri" value="$uri">
	    </form>
    </div>
</container>
</body>
</html>
};
	return undef;
}

sub debug{
	my $message=shift;
	print STDERR "$message\n" if $debug>0;
}


#do not delete last line!
1;
