package App::Monitoring::Plugin::CheckRaid::Plugins::mdstat;

# Linux Multi-Device (md)

use base 'App::Monitoring::Plugin::CheckRaid::Plugin';
use strict;
use warnings;
		   
sub commands {
	{
		'mdstat' => ['<', '/proc/mdstat'],
	}
}

sub active {
	my ($this) = @_;
	# easy way out. no /proc/mdstat
	return 0 unless -e $this->{commands}{mdstat}[1];

	# extra check if mdstat is empty
	my @md = $this->parse;
	return $#md >= 0;
}

sub parse {
	my $this = shift;

	my (@md, %md);
	my $fh = $this->cmd('mdstat');
	my $arr_checking = 0;
	while (<$fh>) {
		chomp;

		# skip first line
		next if (/^Personalities : /);

		# kernel-3.0.101/drivers/md/md.c, md_seq_show
		# md1 : active raid1 sdb2[0] sda2[1]
		if (my($dev, $active, $ro, $rest) = m{^
			(\S+)\s+:\s+ # mdname
			(\S+)\s+     # active: "inactive", "active"
			(\((?:auto-)?read-only\)\s+)? # readonly
			(.+)         # personality name + disks
		}x) {
			my @parts = split /\s/, $rest;
			my $re = qr{^
				(\S+)           # devname
				(?:\[(\d+)\])   # desc_nr
				(?:\((.)\))?    # flags: (W|F|S) - WriteMostly, Faulty, Spare
			$}x;
			my @disks = ();
			my $personality;
			while (my($disk) = pop @parts) {
				last if !$disk;
				if ($disk !~ $re) {
					$personality = $disk;
					last;
				}
				my($dev, $number, $flags) = $disk =~ $re;
				push(@disks, {
					'dev' => $dev,
					'number' => int($number),
					'flags' => $flags || '',
				});
			}

			die "Unexpected parse" if @parts;

			# first line resets %md
			%md = (dev => $dev, personality => $personality, readonly => $ro, active => $active, disks => [ @disks ]);

			next;
		}

		# variations:
		#"      8008320 blocks [2/2] [UU]"
		#"      58291648 blocks 64k rounding" - linear
		#"      5288 blocks super external:imsm"
		#"      20969472 blocks super 1.2 512k chunks"
		#
		# Metadata version:
		# This is one of
		# - 'none' for arrays with no metadata (good luck...)
		# - 'external' for arrays with externally managed metadata,
		# - or N.M for internally known formats
		#
		if (my($b, $mdv, $status) = m{^
			\s+(\d+)\sblocks\s+ # blocks
			# metadata version
			(super\s(?:
				(?:\d+\.\d+) | # N.M
				(?:external:\S+) |
				(?:non-persistent)
			))?\s*
			(.+) # mddev->pers->status (raid specific)
		$}x) {
			# linux-2.6.33/drivers/md/dm-raid1.c, device_status_char
			# A => Alive - No failures
			# D => Dead - A write failure occurred leaving mirror out-of-sync
			# S => Sync - A sychronization failure occurred, mirror out-of-sync
			# R => Read - A read failure occurred, mirror data unaffected
			# U => for the rest
			my ($s) = $status =~ /\s+\[([ADSRU_]+)\]/;

			$md{status} = $s || '';
			$md{blocks} = int($b);
			$md{md_version} = $mdv;

			# if external try to parse dev
			if ($mdv) {
				($md{md_external}) = $mdv =~ m{external:(\S+)};
			}
			next;
		}

		# linux-2.6.33/drivers/md/md.c, md_seq_show
		if (my($action) = m{(resync=(?:PENDING|DELAYED))}) {
			$md{resync_status} = $action;
			next;
		}
		# linux-2.6.33/drivers/md/md.c, status_resync
		# [==>..................]  resync = 13.0% (95900032/732515712) finish=175.4min speed=60459K/sec
		# [=>...................]  check =  8.8% (34390144/390443648) finish=194.2min speed=30550K/sec
		my ($action, $perc, $eta, $speed) = ("none", 0, 0, 0);
		if (($action, $perc, $eta, $speed) = m{(resync|recovery|reshape)\s+=\s+([\d.]+)% \(\d+/\d+\) finish=([\d.]+)min speed=(\d+)K/sec}) {
			$md{resync_status} = "$action:${perc}% ${speed}KiB/s ETA: ${eta}min";
		} elsif (($perc, $eta, $speed) = m{check\s+=\s+([\d.]+)% \(\d+/\d+\) finish=([\d.]+)min speed=(\d+)K/sec}) {
			$md{check_status} = "check:${perc}% ${speed}KiB/s ETA: ${eta}min";
			$action = "check";
			$arr_checking = 1;
		}

		if ($action && $action ne "none") {
			my @perf_data;
			foreach ('check', 'resync', 'recovery', 'reshape') {
				if ($action eq $_) {
					push(@perf_data, sprintf "'%1\$s completed'=%2\$s%%;;;0;100 '%1\$s speed'=%3\$sMiB/s;;;; '%1\$s eta'=%4\$smin;;;;", $action, $perc, $speed / 1024.0, $eta);
				} else {
					push(@perf_data, sprintf "'%1\$s completed'=U;;;0;100 '%1\$s speed'=U;;;; '%1\$s eta'=U;;;;", $_);
				}
			}
			$md{perf_data} = join(' ', @perf_data);
			next;
		}

		# we need empty line denoting end of one md
		next unless /^\s*$/;

		next unless $this->valid($md{dev});

		push(@md, { %md } ) if %md;
	}
	close $fh;

	# One of the arrays is in checking state, which could be because there is a scheduled sync of all MD arrays
	# In such a case, all of the arrays are scheduled to by checked, but only one of them is actually running the check
	# while the others are in "resync=DELAYED" state.
	# We don't want to receive notifications in such case, so we check for this particular case here
	if ($arr_checking && scalar(@md) >= 2) {
		foreach my $dev (@md) {
			if ($dev->{resync_status} && $dev->{resync_status} eq "resync=DELAYED") {
				delete $dev->{resync_status};
				$dev->{check_status} = "check=DELAYED";
			}
		}
	}

	return wantarray ? @md : \@md;
}

sub check {
	my $this = shift;

	my (@status);
	my (@perf_data);
	my @md = $this->parse;

	my @spare_options = ();

	@spare_options = split(/\,/, $this->{options}{mdstat_spare_count})
		if (exists $this->{options}{mdstat_spare_count});

	foreach (@md) {
		my %md = %$_;

		# common status
		my $size = $this->format_bytes($md{blocks} * 1024);
		my $personality = $md{personality} ? " $md{personality}" : "";
		my $s = "$md{dev}($size$personality):";

		# failed disks
		my @fd = map { $_->{dev} } grep { $_->{flags} =~ /F/ } @{$md{disks}};
		# spare disks
		my @sd = map { $_->{dev} } grep { $_->{flags} =~ /S/ } @{$md{disks}};

		my $spare_count = 0;
		OPTION_LOOP:
		{
			foreach my $i (0 .. $#spare_options)
			{
				my ($disk, $value) = split(/:/, $spare_options[$i]);
				for(@md)
				{
					if ($md{dev} eq $disk)
					{
						$spare_count = $value;
						splice(@spare_options, $i, 1);
						last OPTION_LOOP;
					}
				}
			}
		}

		# raid0 is just there or its not. raid0 can't degrade.
		# same for linear, no $md_status available
		if ($personality =~ /linear|raid0/) {
			$s .= "OK";

		} elsif ($md{resync_status}) {
			$this->resync;
			$s .= "$md{status} ($md{resync_status})";

		} elsif ($md{check_status}) {
			$this->check_status;
			$s .= "$md{status} ($md{check_status})";

		} elsif ($md{status} =~ /_/) {
			$this->critical;
			my $fd = join(',', @fd);
			$s .= "F:$fd:$md{status}";

		} elsif (@fd > 0) {
			# FIXME: this is same as above?
			$this->warning;
			$s .= "hot-spare failure:". join(",", @fd) .":$md{status}";
		} elsif (@sd < $spare_count)
		{
			$this->warning;
			$s .= "Array ".$md{dev}." should have ".$spare_count." spares, but has only ".(0+@sd)." spares";
		} else {
			$s .= "$md{status}";
		}
		push(@status, $s);

		if ($md{perf_data}) {
			push(@perf_data, $md{perf_data});
		}
	}

	if (scalar @spare_options > 0)
	{
		$this->critical;
		foreach (@spare_options)
		{
			my ($disk, $value) = split(/:/, $_);
			my $s = "$disk is defined in spare_count option but could not be found!";
			push(@status, $s);
		}
	}

	return unless @status;

	# denote this plugin as ran ok
	$this->ok;

	$this->message(join(', ', @status));
	$this->perfdata(join(' ', @perf_data));
}

1;
