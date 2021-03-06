use warnings;
use strict;
use Data::Dumper;
use markup;

package creole_wiki; 

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(extractEventFromWikiText removeMeta eventToWikiText extractMeta removeMeta metaToWiki);
our %EXPORT_TAGS = ( 'all'  => [ @EXPORT_OK ] );

#convert creole wiki text to event 
sub extractEventFromWikiText{
	my $params=shift;
	my $event=shift;
	$event={} unless (defined $event);

	my $title		=$params->{title}||'';
	my $content		=$params->{content}||'';
	my $local_media_url	=$params->{local_media_url}||'';

	#split content into excerpt, content and comments
	$content=~s/\s*\,\s*/, /g;
	my @lines=split(/\s*\-{10,99}\s*/,$content);
	my $lines=\@lines;
	for my $line (@$lines){
		$line=~s/^\s+|\s+$//g;
	}
	if (@lines==1){
		$event->{content}=shift @lines;
	}elsif(@lines==2){
		$event->{excerpt}=shift @lines;
		$event->{content}=shift @lines;
	}else{
		$event->{excerpt}=shift @lines;
		$event->{content}=shift @lines;
		$event->{comments}=join("--------------------\n",@lines);
	}
	if (defined $event->{excerpt}){
		$event->{excerpt}=markup::html_to_plain($event->{excerpt});
	}
	#extract program from title
	$event->{program}='';

	if ($title=~/^(.*?)\:/){
		my $program=$1;
		unless ($program=~/\s\-\s/){
			$event->{program}=$program;
			$event->{program}=~s/^\s+|\s+$//g;
			$event->{program}=~s/\s+/ /g;
			$title=~s/^.*?\:\s+//gi;
		}
	}

	#extract series_name from title
	$event->{series_name}='';
	if ($title=~/^(.*?)\s+\-\s+/){
		$event->{series_name}=$1;
		$event->{series_name}=~s/^\s+|\s+$//g;
		$event->{series_name}=~s/\s+/ /g;
		$title=~s/^(.*?)\s+\-\s+//gi;
	}
	
	#extract categories from title
	my @categories=();
	while ($title=~/\((.*?),(.*?)\)/){
		my $category=$1;
		$category =~s/\s+/ /g;
		$category =~s/^\s+|\s+$//g;  
		$category =~s/\&/\+/g;  
		push @categories,$category if (defined $category && $category=~/\S/);

		$category='';
		$category=$2 if (defined $2);
		$category =~s/\s+/ /g;
		$category =~s/^\s+|\s+$//g;  
		$category =~s/\&/\+/g;  
		push @categories,$category if (defined $category && $category=~/\S/);
		$title=~s/\((.*?),(.*?)\)/\($2\)/;
	}
	if ($title=~/\((.*?)\)/){
		my $category=$1;
		$category =~s/\s+/ /g;
		$category =~s/^\s+|\s+$//g;  
		$category =~s/\&/\+/g;  

#		print $category."\n";
		push @categories,$category if (defined $category && $category=~/\S/);
		$title=~s/\((.*?)\)//;
	}
	$event->{categories}	= \@categories if (@categories>0);
	$event->{title}		= $title;
	$event->{title}		=~s/^\s+|\s+$//g;

	if (defined $event->{content}){
		#extract podcast_url from content link 'podcast'
		my $podcast_url='';
		if ($event->{content}=~/\[\[\s*([^\|\]]+)\s*\|\s*podcast\s*\]\]/i){
			$podcast_url=$1;
	#		$podcast_url=~s/\|.*//g;
	#		print "found podcast:".$podcast_url."\n";
		}
		$event->{podcast_url}	= $podcast_url;

		#extract media_url from content link 'download'
		my $media_url='';
		if ($event->{content}=~/\[\[\s*([^\|\]]+)\s*\|\s*(direct\s+)?download\s*\]\]/i){
			$media_url=$1;
	#		$podcast_url=~s/\|.*//g;
	#		print "found media:".$media_url."\n";
		}
		$event->{media_url}	= $media_url;

		#replace "thumbs/xxx" link by link to local media URI
		$event->{content}=~s/\{\{\s*thumbs\/+(.*?)\s*\|\s*(.*?)\s*\}\}/\[\[$local_media_url\/images\/$1\|\{\{$local_media_url\/thumbs\/$1\|$2\}\}\]\]/g;

		#extract image from content
		if ($event->{content}=~/\{\{(.*?)(\||\}\})/){
			$event->{image}=$1;
		}
	}

	#meta
	if (defined $event->{comments}){
		my $meta=extractMeta($event->{comments});
		$event->{meta} = $meta if (@$meta>0);
	}

	return $event;
}

sub eventToWikiText{
	my $event=shift;
	my $local_media_url	=$event->{local_media_url}||'';

	$event->{program}	=~s/^\s+|\s+$//g;
	$event->{series_name}	=~s/^\s+|\s+$//g;
	$event->{title}		=~s/^\s+|\s+$//g;
	$event->{excerpt}	=~s/^\s+|\s+$//g;
	$event->{content}	=~s/^\s+|\s+$//g;
	$event->{comments}	=~s/^\s+|\s+$//g;

	my $title='';
	if($event->{program} ne''){
		$title=$event->{program};
		$title.=': ' if (($event->{series_name} ne'') || ($event->{title} ne''));
	}
	if($event->{series_name} ne''){
		$title.=$event->{series_name};
		$title.=' - ' if ($event->{title} ne'');
	}
	$title.=$event->{title};
	if ($event->{categories}){
		$title.=' ('.join(",", @{$event->{categories}} ).')' if (@{$event->{categories}}>0);
	}

	my $meta=extractMeta($event->{comments}, $event->{meta});
	#use Data::Dumper;print "extracted meta".Dumper($meta);

	$event->{comments}=removeMeta($event->{comments});
	$event->{wiki_comments}=$event->{comments}."\n\n".metaToWiki($meta);
	#use Data::Dumper;print "event content".Dumper($event->{content});

	#rich content editors:
	#$event->{wiki_content}=markup::html_to_creole($event->{content});

	#markup editors	
	$event->{wiki_content}=$event->{content};


#	[[http://localhost/agenda_files/media/images/Vl8X7YmaWrmm9RMN_OMywA.jpg|{{http://localhost/agenda_files/media/thumbs/Vl8X7YmaWrmm9RMN_OMywA.jpg|}}]]
	#replace "thumbs/xxx" link by link to local media URI
#	while ($event->{wiki_content}=~/\[\[.*?\/+media\/+images\/+(.*?)\s*\|.*?\{\{.*?\/+media\/+thumbs\/+(.*?)\s*\|\s*(.*?)\s*\}\}\]\]/){
	      $event->{wiki_content}=~s/\[\[.*?\/+media\/+images\/+(.*?)\s*\|.*?\{\{.*?\/+media\/+thumbs\/+(.*?)\s*\|\s*(.*?)\s*\}\}\]\]/\{\{thumbs\/$1\|$3\}\}/g;
#	}

	my $wiki_content=join("\n".("-"x20)."\n",($event->{excerpt}, $event->{wiki_content}) );
	$wiki_content.="\n".("-"x20)."\n".$event->{wiki_comments} if ($event->{wiki_comments}=~/\S/);

	return {
		title		=> $title,
		content		=> $event->{content},
		wiki_content 	=> $wiki_content
	};
	
}

#extrace meta tags from comment text
sub extractMeta{
	my $comments	=shift;
	my $meta	=shift;

	$meta=[] unless (defined $meta);

	#push meta tags into meta list
	if (defined $comments){
		#build index for meta already defined
		my $meta_keys={};
		for my $pair (@$meta){
			$meta_keys->{$pair->{name}.'='.$pair->{value}}=1;
		}

		while ($comments=~/\~\~META\:(.+?)\=(.+?)\~\~/g){
			my $name=$1;
			my $value=$2;

			#fix meta values
			$name=lc($name);
			$name=~s/^\s+|\s+$//g;
			$value=~s/^\s+|\s+$//g;

			#insert into list, if not defined yet
			unless( ($name eq'') || ($value eq'') || (exists $meta_keys->{$name.'='.$value}) ){
				push @$meta,{
					name=>$name,
					value=>$value,
				};
				$meta_keys->{$name.'='.$value}=1;
			}
		};
	}
#	use Data::Dumper;print Dumper($meta);
	return $meta;
}

#remove meta tags from comment text
sub removeMeta{
	my $comments=shift||'';

	my $result='';
	for my $line (split(/\n/,$comments)){
		$result.=$line unless ($line=~/\~\~META\:(.+?)\=(.+?)\~\~/g);
	}
	#use Data::Dumper;print "removed metsas:".Dumper($result);
	$result=~s/^\s+//g;
	$result=~s/\s+$//g;

	return $result;
}

#add meta tags to comment text
sub metaToWiki{
	my $meta	=shift;

	my $result='';
	for my $pair (@$meta){
#		use Data::Dumper;print Dumper($pair);
		$result.='~~META:'.$pair->{name}.'='.$pair->{value}.'~~'."\n";
	}
	return $result;
	#use Data::Dumper;print Dumper($meta);

}


#test:
#perl -e 'use creole_wiki;$a=creole_wiki::extractEventFromWikiText("teaser\n----------------------\nbody[[asd|download]][[bsd|hallo]][[csd|podcast]]{{a|b}}[[dsd|wer]]\n----------------------\ncomments",{title=>" a : b - c ( d e -  f , g h i - j, k - m - l) "});use Data::Dumper;print Dumper($a)';

#do not delete last line!
1;
