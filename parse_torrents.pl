#!/usr/bin/perl -w
#
# Script used to organise downloaded torrents. The basic
# way to set this script up is to make it so that new 
# dowloaded torrents are kept in the directory you define
# as $DL_DIR. Then you are expected to have a directory
# just for movies that you define as $MOVIES_DIR and a
# separate directory you define as $SHOWS_DIR for your
# tv shows. This script will search all the files and 
# folders in the new downloads directory and it will 
# find any video files or .rar files and attempt to 
# identify whether they belong to movies or tv shows and
# which movie or which show, season and episode. 
#
# It will also skip files that it thinks are samples or 
# .rars that it thinks are subtitles.
#
# Note: Files will be deleted from the downloads 
# directory and MOVED (not copied) to the appropriate
# folder. If nothing is found in a torrent folder it
# won't be deleted.
#
# Default behaviour :
#
# The default is to ask for classification details about
# unknown files. Files assumed Subs and sample are simply
# skipped and these will not be confirmed. Fully 
# identified files will also be processed without 
# confirmation. User input will be needed for partially
# unidentified files as well.
#
#
# By Dylan Griffith
#
#

# Some initial definitions
use File::Find;
use File::Basename;
use File::Copy;
#use strict; # Add this when you get around to it
use warnings;
use Getopt::Long::Descriptive;
use Data::Dumper;
our $debug = 0;
our $UNKNOWN = -1;
our $EPISODE = 1;
our $MOVIE = 2;
our $DL_DIR = "/data/torrents/staging"; # Default
our $SHOWS_DIR = "/data/share/shows"; # Default
our $MOVIES_DIR = "/data/share/movies"; # Default
our %warnings;
$warnings{"FILE_EXISTS"} = "\t- parse_torrents.pl: Warning 505 skipping (target file already exists)";
$warnings{"CD_EPSIODE"} = "\t- parse_torrents.pl: Warning 511 skipping (identified as episode but also cd, this shouldn't be)";
$warnings{"UNKNOWN_TYPE"} = "\t- parse_torrents.pl: Warning 510 (could not identify type)";
$warnings{"SAMPLE"} =  "\t- parse_torrents.pl: Warning 500 skipping (assumed sample)";
$warnings{"SUBS"} = "\t- parse_torrents.pl: Warning 501 skipping (assumed subs)";
our $torrent_name;
sub identify($);
sub is_video($);
sub video_process($);
sub rar_process($);
my ($type,$title,$season,$episode,$year);
our $found;
our $forceful = 0;
our $anti_forceful = 0;
our $replacement = 0;
our $no_delete = 0;
our $commands = "";
my $choice;

# Handle all optional arguments
my ( $opt, $usage ) = describe_options(
	'parse_torrents.pl %o',
	[ 'downloads|t=s', 'Directory where newly downloaded torrents are stored', { default => $DL_DIR }],
	[ 'movies|m=s', 'Directory where Movies are stored', { default => $MOVIES_DIR }],
	[ 'shows|s=s', 'Directory where TV Shows are stored', { default => $SHOWS_DIR }],
	[],
	[ 'replacement|r', 'Use if you want to replace existing files when moving across discovered files (risky option)'],
	[ 'forceful|f', 'Use if you do not want to be asked anything and have script make all decisions (risky option)'],
	[ 'antiforceful|a', 'Use if you want to be asked to confirm every decision (safe option)'],
	[ 'nodelete|n', 'Use if you do not want files to be moved, but rather copied so all files will remain in downloads directory (safe option)'],
	[ 'help',      'print usage message and exit' ],
);

$DL_DIR = $opt->downloads;
$MOVIES_DIR = $opt->movies;
$SHOWS_DIR = $opt->shows;

print($usage->text), exit if $opt->help;
print "***---------------***----------------***---------------***\n";
if ($opt->replacement) {
	print "Using Replacement\n";
	$replacement = 1;
}
if ($opt->forceful) {
	print "Using Forceful\n";
	$forceful = 1;
}
if ($opt->antiforceful) {
	print "Using Anti-forceful\n";
	$anti_forceful = 1;
}
if ($opt->nodelete) {
	print "Using No-delete\n";
	$no_delete = 1;
}
print "Downloads directory is $DL_DIR\n";
print "Movies directory is $MOVIES_DIR\n";
print "TV Shows directory is $SHOWS_DIR\n";

if($replacement) {
	$warnings{"FILE_EXISTS"} = "\t- parse_torrents.pl: Warning 905 OVERWRITING (target file already exists)";
}
if($forceful && $anti_forceful) {
	print "\nError: Can't be both forceful and anti-forceful. Terminating...\n\n";
	exit(0);
}
print "***---------------***----------------***---------------***\n";

# Loop over all directories in DL_DIR
foreach $torrent_name (glob "$DL_DIR/*") {
	$found = 0;
	print "\n\t*** $torrent_name ***\n";
	# Recursively search directory
	find(\&file_process,$torrent_name);
	# Delete directory if a file was found
	if ($found > 0) {
		print "\t--- SUCCESS: $found files found (deleting $torrent_name)\n";
		if($anti_forceful) {
			print "[C]onfirm delete or any other key to skip\n";
			$choice = <STDIN>;
			if($choice !~ m/^C$/i) {
				next;
			}
		}
		$torrent_name_safe = $torrent_name;
		$torrent_name_safe =~ s/ /\\ /g; # Make sure spaces are preceeded by \ for shell unrar
		$torrent_name_safe =~ s/([()])/\\$1/g; # Make sure brackets are preceeded by \ for shell unrar
		$commands .= "rm -rf $torrent_name_safe\n" if !$no_delete;
	}else {
		print "\t--- FAILURE: Zero files found (not deleting $torrent_name)\n";
	}
}

# Print commands to file then execute
$temp_file_name = "/tmp/parse_torrents_commands.sh";
open F, ">$temp_file_name" or die;
print F $commands;
close F;
system "sh < $temp_file_name";
system "rm $temp_file_name";

# Start point for processing a found file
sub file_process {
	# Skip directories
	return if -d;
	my $file_name = $_ or die "argument was $_";
	my $dir_name = $File::Find::dir;
	my $full_file = $File::Find::name;
	if(is_video($file_name)) {
		video_process($full_file);
	}elsif($file_name =~ m/.rar$/) {
		rar_process($full_file);
	}
}

# Process a video file that has been found
sub video_process($) {
	my ($type,$title,$season,$episode,$year);
	my $is_cd = 0;
	my $cd_num;
	my $full_file = $_[0] or die;
	our $found;
	# Skip if it is just a sample video
	if ($full_file =~ m/sample/i) {
		if($anti_forceful) {
			while (1) {
				print "Treat $full_file as sample [y/n]?\n";
				$choice = <STDIN>;
				chomp $choice;
				return if ($choice =~ m/^y$/i);
				last if ($choice =~ m/^n$/i);
			}
		}else {
			print "$warnings{SAMPLE} - $full_file\n";
			return;
		}
	}
	# Check if the video is in more than one part eg. <Movie.Year.cdN>
	if ($full_file =~ m/cd(\d+)/i) {
		$is_cd = 1;
		$cd_num = $1;
	}
	# Identify the type of file
	($type,$title,$season,$episode,$year) = identify($full_file);
	# Report final classification of file and finalise processing
	if($type == $UNKNOWN) {
		print "$warnings{UNKNOWN_TYPE} - $full_file\n";
	}elsif($type == $EPISODE) {
		$full_file =~ m/.+\.(.+)$/ or die;
		$ext = $1 or die;
		$new_name = sprintf("%s.S%02dE%02d.%s",$title,$season,$episode,$ext);
		# Check for weird situation where episode is in two parts (if so skip it and give warning)
		if ($is_cd) {
			print "$warnings{CD_EPISODE} - $full_file\n";
			return;
		}
		if (!$debug) { 
			# Make directory for tv show unless it exists
			my $show_dir = "$SHOWS_DIR/$title";
			mkdir $show_dir unless (-d $show_dir);
			# Make directory for season unless it exists
			my $season_dir = sprintf("$show_dir/Season.%02d",$season);
			mkdir $season_dir unless (-d $season_dir);
			# Move the episode to the season dir with new name unless it exists
			$target = "$season_dir/$new_name";
			if(-e $target) {
				print "$warnings{FILE_EXISTS} - $full_file\n";
				return if (!$replacement);
			}
			if($anti_forceful) {
				while (1) {
					print "Episode: $new_name parse from $full_file [y/n]?\n";
					$choice = <STDIN>;
					chomp $choice;
					last if ($choice =~ m/^y$/i);
					return if ($choice =~ m/^n$/i);
				}
			}
			if ($no_delete) {
				copy($full_file,$target);
			}else {
				move($full_file,$target);
			}
			$found++;
		}	
		print "\t+ parse_torrents.pl: TV Show episode parsed as $new_name from $full_file\n";
	}elsif($type == $MOVIE) {
		$full_file =~ m/.+\.(.+)$/ or die;
		$ext = $1 or die;
		if ($is_cd) { # Multi-part movie
			$new_name = sprintf("%s.(%d).cd%d.%s",$title,$year,$cd_num,$ext);
		}else { # Single-part movie
			$new_name = sprintf("%s.(%d).%s",$title,$year,$ext);
		}
		if (!$debug) { 
			# Make directory for movie unless it exists
			my $movie_dir = "$MOVIES_DIR/$title.($year)";
			mkdir $movie_dir unless (-d $movie_dir);
			# Move the movie to the movie dir with new name unless it exists
			$target = "$movie_dir/$new_name";
			if(-e $target) {
				print "$warnings{FILE_EXISTS} - $full_file\n";
				return if(!$replacement);
			}
			if($anti_forceful) {
				while (1) {
					print "Movie: $new_name parse from $full_file [y/n]?\n";
					$choice = <STDIN>;
					chomp $choice;
					last if ($choice =~ m/^y$/i);
					return if ($choice =~ m/^n$/i);
				}
			}
			if ($no_delete) {
				copy($full_file,$target);
			}else {
				move($full_file,$target);
			}
			$found++;
		}
		
		print "\t+ parse_torrents.pl: Movie parsed as $new_name from $full_file\n";	
	}else {
		die "An error occured and the type of file was $type, file was $full_file";
	}
}

# Process a rar file. Note that this time the
# parent directory of the file will be used to
# identify it
sub rar_process($) {
	my $cd_num;
	my $is_cd = 0;
	my ($type,$title,$season,$episode,$year);
	my $full_file = $_[0] or die;
	our $found;
	# Check for stupid rar standard where files are listed <blah.part00.rar>
	my $is_part = 0;
	if ($full_file =~ m/part(\d+).rar/) {
		# Skip unless it is part01
		my $part_num = $1;
		return unless $part_num == 1;
		$is_part = 1;
	}
	# Get the name of the file without directory structure
	my ($base_name,$null1,$null2) = fileparse($full_file);
	# Skip file if subs
	if ($full_file =~ m/\/subs\//i) {
		if($anti_forceful) {
			print "Treat $full_file as subs (y/n)?\n";
			$choice = <STDIN>;
			chomp $choice;
			return if ($choice =~ m/^y$/i);
			last if ($choice =~ m/^n$/i);
		}else {
			print "$warnings{SUBS} - $full_file\n";
			return;
		}
	}
	# Check if path contains CD1 or CD2 as in many movie files
	if ($full_file =~ m/cd(\d)/i) {
		$is_cd = 1;
		$cd_num = $1;
	}
	($type,$title,$season,$episode,$year) = identify($full_file);
	if($type == $UNKNOWN) {
		print "$warnings{UNKNOWN_TYPE} - $full_file\n";
	}elsif($type == $EPISODE) {
		$new_name = sprintf("%s.S%02dE%02d.",$title,$season,$episode);
		if ($is_cd) {
			print "$warnings{CD_EPISODE} - $full_file\n";
			return;
		}
		if (!$debug) { 
			if($anti_forceful) {
				while (1) {
					print "Episode: $new_name parsed from $full_file [y/n]?\n";
					$choice = <STDIN>;
					chomp $choice;
					last if ($choice =~ m/^y$/i);
					return if ($choice =~ m/^n$/i);
				}
			}
			# Make directory for tv show unless it exists
			my $show_dir = "$SHOWS_DIR/$title";
			mkdir $show_dir unless (-d $show_dir);
			# Make directory for season unless it exists
			my $season_dir = sprintf("$show_dir/Season.%02d",$season);
			mkdir $season_dir unless (-d $season_dir);
			# Move the episode to the season dir with new name unless it exists
			my @matches = glob("$season_dir/$new_name*");
			my $n_matches = @matches;
			if($n_matches > 0)  {
				print "$warnings{FILE_EXISTS} - $full_file\n";
				return if (!$replacement);
			}
			# unrar the rar to the season dir
			$full_file_safe = $full_file;
			$full_file_safe =~ s/ /\\ /g; # Make sure spaces are preceeded by \ for shell unrar
			$full_file_safe =~ s/([()])/\\$1/g; # Make sure brackets are preceeded by \ for shell unrar
			# Use this line if you want to be asked to overwrite files
			#$commands .= "/usr/bin/unrar x $full_file_safe $season_dir/ > /dev/null\n";
			# Use this line if you want to automatically OVERWRITE files
			#$commands .= "/usr/bin/unrar x -o+ $full_file_safe $season_dir/ > /dev/null\n";
			# Use this line if you want to automatically NOT OVERWRITE files
			$commands .= "/usr/bin/unrar x -o- $full_file_safe $season_dir/ > /dev/null\n";
			$found++;
			# Rename the extracted files (assuming they have the same name
			# as the .rar but just different extension)
			$base_name_without_ext = $base_name;
			$base_name_without_ext =~ s/[^.]+$//;
			# Remove the part01 bit from the filename if it is such a rar file
			if ($is_part) {
				$base_name_without_ext =~ s/part0*1\.$//;
			}
			$commands .= "/usr/bin/rename.pl 's/$base_name_without_ext/$new_name/i' $season_dir/*\n";
		}
		print "\t+ parse_torrents.pl: TV Show episode parsed as $new_name from $full_file\n";
	}elsif($type == $MOVIE) {
		if ($is_cd) {
			$new_name = sprintf("%s.(%d).cd%d.",$title,$year,$cd_num);
		}else {
			$new_name = sprintf("%s.(%d).",$title,$year);
		}
		if (!$debug) { 
			if($anti_forceful) {
				while (1) {
					print "Movie: $new_name parsed from $full_file [y/n]?\n";
					$choice = <STDIN>;
					chomp $choice;
					last if ($choice =~ m/^y$/i);
					return if ($choice =~ m/^n$/i);
				}
			}
			# Make directory for movie unless it exists
			my $movie_dir = "$MOVIES_DIR/$title.($year)";
			mkdir $movie_dir unless (-d $movie_dir);
			# unrar the rar to the season dir
			$full_file_safe = $full_file;
			$full_file_safe =~ s/ /\\ /g; # Make sure spaces are preceeded by \ for shell unrar
			$full_file_safe =~ s/([()])/\\$1/g; # Make sure brackets are preceeded by \ for shell unrar
			$movie_dir_safe = $movie_dir;
			$movie_dir_safe =~ s/([()])/\\$1/g; # Make sure brackets are preceeded by \ for shell unrar
			# Move the movie to the movie dir with new name unless it exists
			my @matches = glob("$movie_dir/$new_name*");
			my $n_matches = @matches;
			if($n_matches > 0) {
				print "$warnings{FILE_EXISTS} - $full_file\n";
				return if(!$replacement);
			}
			# Use this line if you want to be asked to overwrite files 
#			$commands .= "/usr/bin/unrar x $full_file_safe $movie_dir_safe/ > /dev/null\n";
			# Use this line if you want to automatically OVERWRITE files
			#$commands .=  "/usr/bin/unrar x -o+ $full_file_safe $movie_dir_safe/ > /dev/null\n";
			# Use this line if you want to automatically NOT OVERWRITE files
			$commands .= "/usr/bin/unrar x -o- $full_file_safe $movie_dir_safe/ > /dev/null\n";
			$found++;
			# Rename the extracted files (assuming they have the same name
			# as the .rar but just different extension)
			$base_name_without_ext = $base_name;
			$base_name_without_ext =~ s/[^.]+$//;
			# Remove the part01 bit from the filename if it is such a rar file
			if ($is_part) {
				$base_name_without_ext =~ s/part0*1\.$//;
			}
			$commands .= "/usr/bin/rename.pl 's/$base_name_without_ext/$new_name/i' $movie_dir_safe/*\n";
		}
		print "\t+ parse_torrents.pl: Movie parsed as $new_name from $full_file\n";	
	}else {
		die "An error occured and the type of file was $type, file was $full_file";
	}
}

# Identify the type of file as well as parse the details from the name
sub identify($) {
	my $name = $_[0] or die;
	my $line;
	# Remove the ignore words from the name before parsing
	my @ignore_words = qw/unrated uncut xvid divx brrip dvdrip bluray/;
	foreach $ignore (@ignore_words) {
		$name =~ s/$ignore//i;
		# Remove double spaces and double dots
		$name =~ s/  / /g;
		$name =~ s/\.\././g;
	}
	my ($type,$title,$season,$episode,$year);
	# Check for episode of the form <Show.S00E00>
	if ($name =~ m/.*\/([\-\w.\s]+)S(\d\d)E(\d\d)/i) {
		($type,$title,$season,$episode,$year)  = ($EPISODE,$1,$2,$3,0);
	# Check for epsiode of the form <Show.00x00>
	}elsif ($name =~ m/.*\/([\-\w.\s]+)(\d+)x(\d+)/i) {
		($type,$title,$season,$episode,$year)  = ($EPISODE,$1,$2,$3,0);
	# Check for movie name of the form <Title.Year.Blah>
	}elsif ($name =~ m/([\-\s\w.]+)[\[\(]?(\d\d\d\d)[\]\)]?/) {
		($type,$title,$season,$episode,$year)  = ($MOVIE,$1,0,0,$2);
	}else {
		($type,$title,$season,$episode,$year)  = ($UNKNOWN,0,0,0,0);
		# In this case get user to manually enter details or choose to skip
		if (!$forceful) {
			$done = 0;
			while (!$done) {
				print "\n\t>>>>>>>>>> Can't identify $name <<<<<<<<<<\n";
				while (1) {
					print "Select [m]ovie, [e]pisode, [s]kip\n";
					$line = <STDIN>;
					chomp $line;
					if ($line =~ m/m/i) {
						$type = $MOVIE;
						print "Enter title: ";
						$title = <STDIN>;
						chomp $title;
						print "Enter year: ";
						$year = <STDIN>;
						chomp $year;
						# Check validity of year
						if ($year !~ m/^\d\d\d\d$/) {
							print "Year must be four numbers. Start again.\n";
							next;
						}
						$season = 0;
						$episode = 0;
						$done = 1;
						last;
					}elsif ($line =~ m/e/i) {
						$type = $EPISODE;
						print "Enter title: ";
						$title = <STDIN>;
						chomp $title;
						print "Enter season: ";
						$season = <STDIN>;
						chomp $season;
						print "Enter episode: ";
						$episode = <STDIN>;
						chomp $episode;
						# Check validity of season and episode
						if ($season =~ m/\D/ or $episode =~ m/\D/) {
							print "Season and episode must be whole numbers. Start again.\n";
							next;
						}elsif ($season > 100 or $episode > 100) {
							print "Season and episode must be less than 100. Start again.\n";
							next;
						}
						$year = 0;
						$done = 1;
						last;
					}elsif ($line =~ m/s/i) {
						$done = 1;
						last;
					}
				}
			}
		}
	}
	# Replace spaces or underscores with '.'
	$title =~ s/[ \_]/./g;
	# Remove pairs of dots
	$title =~ s/\.\././g;
	# Remove trailing dots
	$title =~ s/\.+$//;
	$title =~ s/^\.+//;
	# Make all and only first letters uppercase
	$title =~ tr/A-Z/a-z/;
	$title =~ s/^(.)/uc($1)/e;
	$title =~ s/(\..)/uc($1)/ge;
	return ($type,$title,$season,$episode,$year);
}

# True if the file is a video file and false otherwise
sub is_video($) {
	my $file_name = $_[0] or die;
	my @vid_exts = qw/.avi .mp4 .mkv .mpg .wmv/;
	foreach (@vid_exts){
		return 1 if ($file_name =~ m/$_$/);
	}
	return 0;
}
