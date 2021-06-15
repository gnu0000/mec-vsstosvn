#!c:/Perl/bin/perl.exe
#

use strict;
use Win32;

my $LOCALENV     = {};
my $REPOSITORIES = {};
my $PASSWORDS    = {};

MAIN:
   Init ();

   my ($Histories, $Projects);
   if ($ARGV[1] =~ /continue/i)
      {
      print "Continuing by using the stored filelist\n";
      $Projects = LoadFromFile ($LOCALENV->{directories_file}, 0);  
      BuildTree ($Projects);
      ImportTree ($Projects);
      $Histories = LoadFromFile ($LOCALENV->{histories_file}, 1);
      }
   else
      {
      $Projects = ExportTree ();
      BuildTree ($Projects);
      ImportTree ($Projects);

      my $FileList = ExtractFilelist ($Projects);
      $Histories = ExtractHistories ($FileList);
      }

   CheckPasswords ($Histories);

   # This works, but it gives a revision per file update
   # TransferHistories ($Histories);

   # group updates
   my $Revisions = BuildRevisionList ($Histories);
   TransferRevisions ($Revisions);

   # cleanup work area
   _ChangeDir ($LOCALENV->{work_area});
   my ($ProjectDir) = $REPOSITORIES->{vss_project} =~ m[^\$/(.*)$];
   _RemoveTree ($ProjectDir) if !($ProjectDir =~ m[^\s*\\\/\s*$]);
   _ChangeDir ("..");

   exit (0);

####################################################################

sub Init
   {
   ($LOCALENV, $REPOSITORIES, $PASSWORDS) = ReadCfg ($ARGV[0] or "VSSToSVN.cfg");
   $LOCALENV->{basename} = 

   open (STDERR, ">", $LOCALENV->{log_file});

   $ENV{'SSDIR'} = $REPOSITORIES->{vss_repository};

   print "-------------------------------------------------\n";
   print "vss_repository : $REPOSITORIES->{vss_repository} \n";
   print "vss_project    : $REPOSITORIES->{vss_project}    \n";
   print "svn_repository : $REPOSITORIES->{svn_repository} \n";
   print "svn_project    : $REPOSITORIES->{svn_project}    \n";
   print "-------------------------------------------------\n";
   }


sub ExportTree
   {
   print ("Gathering Directory tree info...\n");
   my $Result = VssExec ("Dir \"$REPOSITORIES->{vss_project}\" -I- -R -F-");
   $Result =~ s/\n((\w*\-*\.*\w*\/*\s*)+\:)/ $1/g; # unwrap lines

   my @Projects = ();

   my @Lines = split ('\n', $Result);
   foreach my $Line (@Lines)
      {
      if ($Line =~ /(.*)\:/)
         {
         chop($Line);
         push(@Projects, $Line);
         }
      }
   sort(@Projects);
   DumpToFile ($LOCALENV->{directories_file}, \@Projects);
   return \@Projects;
   }


sub BuildTree
   {
   my ($Projects) = @_;

   print ("Building Dir Tree...\n");
   _MakeDir ($LOCALENV->{work_area});
   _ChangeDir ($LOCALENV->{work_area});
   _MakeDir ($_) foreach (@{$Projects});
   _ChangeDir ("..");
   }


sub ImportTree
   {
   print ("Creating Directory Tree in Subversion...\n");

   my ($ProjectDir) = $REPOSITORIES->{vss_project} =~ m[^\$/(.*)$];

   _ChangeDir ($LOCALENV->{work_area});
   SvnExec (" import \"$ProjectDir\" $REPOSITORIES->{svn_repository}/$REPOSITORIES->{svn_project} -m\"Dir Created by Migration Utility\"");
   _RemoveTree ($ProjectDir) if !($ProjectDir =~ m[^\s*\\\/\s*$]);
   SvnExec (" checkout $REPOSITORIES->{svn_repository}/$REPOSITORIES->{svn_project} \"$ProjectDir\"");
   _ChangeDir ("..");
   }


sub ExtractFilelist
   {
   my ($Projects) = @_;
   
   my @FileList = ();

   print ("Gathering File List...");
   foreach my $Project (@{$Projects})
      {
      my $Result = VssExec ("Dir \"$Project\" -I- -R-");
      $Result =~ s/\n((\w*\-*\.*\w*\/*\s*)+\:)/ $1/g; # unwrap lines

      my @lines = split('\n', $Result);
      foreach my $Line (@lines)
         {
         next if $Line =~ m[\$];
         next if $Line =~ m[/];
         next if $Line =~ m[\(s\)];
         next if !$Line;
         push @FileList, "$Project/$Line";
         }
      }
   DumpToFile ($LOCALENV->{files_file}, \@FileList);
   print ("\n");
   return \@FileList;
   }


sub ExtractHistories
   {
   my ($FileList) = @_;

   print ("Extracting File History Data...");
   my @HistoryData = ();
   foreach my $File (@{$FileList})
      {
      my $Result = VssExec ("History \"$File\" -I-");
      push @HistoryData, _ExtractHistoryData ($File, $Result);
      }
   DumpToFile ($LOCALENV->{histories_file}, \@HistoryData);

   map {printf STDERR "$_->[0], $_->[1], $_->[2], $_->[3], $_->[4], $_->[5]\n";} (@HistoryData);

   print ("\n");
   return \@HistoryData;
   }


sub _ExtractHistoryData
   {
   my ($File, $Result) = @_;
   my ($Version, $User, $Date, $Time, $Comment, $Label);

   my ($Filename) = $File =~ m[^\$/(.*)$];

   my @FileHistory = ();
   my @Lines = split('\n', $Result);
   foreach my $Line (@Lines)
      {
      if ($Version && $Line =~ /\*\*\*\*\*/)
         {
         my $Record = [$Filename, $Version, $User, $Date, $Time, $Comment];
         push @FileHistory, $Record;
         ($Version, $User, $Date, $Time, $Comment, $Label) = ();
         }
      $Version = $1 if ($Line =~ /\*  Version (\d+)/  );
      $User    = $1 if ($Line =~ /User: (\w+) /       );
      $Date    = $1 if ($Line =~ /Date: ( ?[\/\d]+) / );
      $Time    = $1 if ($Line =~ /Time: ( ?[\d:ap]+)/ );
      $Comment = $1 if ($Line =~ /Comment: (.*)$/     );
      $Label   = $1 if ($Line =~ /Label: \"(.*)\"/    );
      }
   return sort {$a->[1] <=> $b->[1] || $a->[3] cmp $b->[3] || $a->[4] cmp $b->[4]} @FileHistory;
   }


# This works, but it gives a revision for each file/history
#
#
#sub TransferHistories
#   {
#   my ($Histories) = @_;
#   my ($PrevFilename);
#
#   print ("Transferring Files ...");
#   _ChangeDir ($LOCALENV->{work_area});
#   foreach my $History (@{$Histories})
#      {
#      my ($Filename, $Version, $User, $Date, $Time, $Comment) = @{$History};
#      my ($Dir)    = $History->[0] =~ m{^(.*)/[^/]+$};
#      my $Result   = VssExec ("Get -GTM -W -I- -Yadmin,admin -I- -GL\"$Dir\" -V" . int ($Version). " \"\$/$Filename\"");
#      my $User     = lc $User;
#
#      if ($Filename ne $PrevFilename)
#         {
#         print ("\nTransferring File history for $Filename.");
#         SvnExec ("add \"$Filename\"");
#         }
#      else
#         {
#         print (".");
#         }
#      my ($ProjDir, $RelativePath) = $Filename =~ m{([^/]+)/(.+)$};
#      _ChangeDir ($ProjDir);
#      SvnExec ("commit --non-interactive --non-recursive --username $User --password $PASSWORDS->{$User} --message \"$Comment\" \"$RelativePath\"");
#      _ChangeDir ("..");
#
#      $PrevFilename = $Filename;
#      }
#   print ("\n");
#   _ChangeDir ("..");
#   }


sub TransferRevisions 
   {
   my ($Revisions) = @_;

   print ("Transferring Files ...\n");
   _ChangeDir ($LOCALENV->{work_area});
   my $i = 2;
   foreach my $Revision (@{$Revisions})
      {
      print "Transferring revision #$i ["; $i++;

      map {CheckoutRevisionFile ($_); print ".";} @{$Revision};
      print "]";
      CheckinRevision ($Revision->[0]);
      print "\n";
      }
   my ($ProjectDir) = $REPOSITORIES->{vss_project} =~ m[^\$/(.*)$];
   _RemoveTree ($ProjectDir) if !$ProjectDir =~ "[\\\/]";
   _ChangeDir ("..");
   }


sub CheckoutRevisionFile
   {
   my ($History) = @_;

   my ($Filename, $Version, $User, $Date, $Time, $Comment) = @{$History};
   my ($Dir)  = $History->[0] =~ m{^(.*)/[^/]+$};
   my $Result = VssExec ("Get -GTM -W -I- -Yadmin,admin -I- -GL\"$Dir\" -V" . int ($Version). " \"\$/$Filename\"");
   my $User   = lc $User;
   SvnExec ("add \"$Filename\""); # we don't know if it has been added already
   }


sub CheckinRevision
   {
   my ($History) = @_;

   my ($Filename, undef, $User, undef, undef, $Comment) = @{$History};
   $User = lc $User;
   my ($ProjectDir)   = $REPOSITORIES->{vss_project} =~ m[^\$/(.*)$];
   my ($RelativePath) = $Filename =~ m{^$ProjectDir/(.+)$};
   
   die "could not extract relative path from [$Filename] in project [$ProjectDir]\n" if !$RelativePath;

   my $old_dir = Win32::GetCwd ();
   _ChangeDir ($ProjectDir);
#   print STDERR SvnExec ("stat") . "\n";
#   print STDERR SvnExec ("commit --non-interactive --username $User --password $PASSWORDS->{$User} --message \"$Comment\"") . "\n";
   SvnExec ("commit --non-interactive --username $User --password $PASSWORDS->{$User} --message \"$Comment\"") . "\n";
   Win32::SetCwd($old_dir);
   }


sub DateRep
   {
   my ($DateField) = @_;
   my ($Month,$Day,$Year) = $DateField =~ m[^\s*(\d+)/(\d+)/(\d+)\s*$];
   ($Month && $Day && $Year) or die "Couldn't parse date $DateField";
   return $Year*500 + $Month*31 + $Day; # no need to be exact
   }


sub TimeRep
   {
   my ($TimeField) = @_;
   my ($Hour,$Min,$ap) = $TimeField =~ m[^\s*(\d+):(\d+)([ap])\s*$];
   $Hour && $Min && $ap or die "Couldn't parse time $TimeField";
   return $Hour*60 + $Min + lc($ap) eq 'p' ? 720 : 0;
   }


sub BuildRevisionList 
   {
   my ($Histories) = @_;
   map {push @{$_}, (DateRep ($_->[3]), TimeRep ($_->[4]));} @{$Histories};

   # sort by date, then filename, then revision
   my @DateOrder = sort {$a->[6] <=> $b->[6] or $a->[0] cmp $b->[0] or $a->[1] <=> $b->[1]} @{$Histories};
   #  DumpHistories (\@DateOrder);

   my @Revisions = ();
   while (1)
      {
      my $Revision = ExtractFirstRevision (\@DateOrder);
      last if !$Revision->[0];
      push @Revisions, $Revision;
      }
   return \@Revisions;
   }


sub ExtractFirstRevision
   {
   my ($DateOrderedHistory) = @_;

   my ($CurrentDate, $CurrentFile, $CurrentDesc, $CurrentUser, @Revision);

   foreach my $History (@{$DateOrderedHistory})
      {
      next if !$History;
      
      next if ($History->[0] eq $CurrentFile); #print ("compare#2 $History->[0] vs $CurrentFile\n");

      $CurrentDate = $History->[6] if !$CurrentDate;
      $CurrentFile = $History->[0] if !$CurrentFile;
      $CurrentDesc = $History->[5] if !$CurrentDesc;
      $CurrentUser = $History->[2] if !$CurrentUser;

      last if ($History->[6] != $CurrentDate); #print ("compare#1 $History->[6] vs $CurrentDate\n");
      next if ($History->[5] ne $CurrentDesc); #print ("compare#3 $History->[5] vs $CurrentDesc\n");
      next if ($History->[2] ne $CurrentUser); #print ("compare#3 $History->[2] vs $CurrentUser\n");

      push @Revision, $History;
      $History = undef;
      }
   return \@Revision;
   }


sub CheckPasswords
   {
   my ($Histories) = @_;

   my %Passwords;
   map {$Passwords{lc $_->[2]} = 1} @{$Histories};
   
   foreach my $User (sort keys %Passwords)
      {
      next if defined $PASSWORDS->{$User};
      my $Message = "### ERROR! ###: user $User does not have an entry in the [passwords] section of the config file!\n";
      print $Message;
      print STDERR $Message;
      }
   }


sub ReadCfg
   {
   my ($FileName) = @_;
   my ($FileHandle, $Line, $Section);

   my $Ref = {};
   open ($FileHandle, "<", $FileName) or die "Cannot open $FileName";
   while ($Line = <$FileHandle>)
      {
      chomp $Line;
      next if !$Line || $Line =~ /^#/;
      $Section = lc $1 if $Line =~ /^\s*\[(\w+)\]\s*$/;
      $Ref->{$Section}->{lc $1} = $2 if $Line =~ /^\s*(\w+)\s*=\s*"(.*)"\s*$/;
      }
   die "Cannot find section [environment]  in file $FileName\n"                     if !$Ref->{environment};
   die "Cannot find section [repositories] in file $FileName\n"                     if !$Ref->{repositories};
   die "Cannot find section [passwords]    in file $FileName\n"                     if !$Ref->{passwords};
   die "Cannot find vss_install_path in section [environment]  in file $FileName\n" if !$Ref->{environment}->{vss_install_path};
   die "Cannot find svn_install_path in section [environment]  in file $FileName\n" if !$Ref->{environment}->{svn_install_path};
   die "Cannot find work_area        in section [environment]  in file $FileName\n" if !$Ref->{environment}->{work_area};
   die "Cannot find vss_repository   in section [repositories] in file $FileName\n" if !$Ref->{repositories}->{vss_repository};
   die "Cannot find vss_project      in section [repositories] in file $FileName\n" if !$Ref->{repositories}->{vss_project};
   die "Cannot find svn_repository   in section [repositories] in file $FileName\n" if !$Ref->{repositories}->{svn_repository};
   die "Cannot find svn_project      in section [repositories] in file $FileName\n" if !$Ref->{repositories}->{svn_project};

   # build additional environmental stuff
   $Ref->{environment}->{config}   = $FileName;
   my ($BaseName) = $FileName =~ /^([^.]+)\.\w+$/ or die "Whats this config name?: $FileName\n";
   $Ref->{environment}->{log_file}         = $BaseName . "_Log.txt";
   $Ref->{environment}->{files_file}    = $BaseName . "_Files.txt";
   $Ref->{environment}->{directories_file} = $BaseName . "_Directories.txt";
   $Ref->{environment}->{histories_file}   = $BaseName . "_Histories.txt";

   return ($Ref->{environment}, $Ref->{repositories}, $Ref->{passwords});
   }

sub VssExec
   {
   my ($CmdInfo) = @_;

   my $CmdLine = "$LOCALENV->{vss_install_path}\\ss.exe $CmdInfo";
   printf STDERR "Executing: $CmdLine\n";
   my $Return = `$CmdLine`;
   return $Return;
   }


sub SvnExec
   {
   my ($CmdInfo) = @_;

   my $CmdLine = "$LOCALENV->{svn_install_path}\\svn.exe $CmdInfo";
   printf STDERR "Executing: $CmdLine\n";
   my $Return = `$CmdLine`;
   return $Return;
   }


sub DumpToFile
   {
   my ($FileName, $List) = @_;
   my $FileHandle;

   open ($FileHandle, ">", $FileName) or die "Cannot open $FileName";
   map {print $FileHandle (ref ($_) ? join (',', @{$_}) : $_) . "\n"} @{$List};
   close $FileHandle;
   }


sub LoadFromFile
   {
   my ($FileName, $IsArray) = @_;
   my $FileHandle;

   my @Data = ();
   open ($FileHandle, "<", $FileName) or die "Cannot open $FileName";
   map {chomp $_; push @Data, ($IsArray ? [split (',', $_)] : $_);} (<$FileHandle>);
   close $FileHandle;
   return \@Data;
   }


sub _ChangeDir
   {
   my ($Dir) = @_;
   chdir ($Dir);
   printf STDERR "Chdir: $Dir\n";
   }

sub _MakeDir
   {
   my ($LocalPath) = @_;
   $LocalPath =~ s[^\$/(.*)$][$1];
   my @Dirs = split ('/', $LocalPath);

   my $old_dir = Win32::GetCwd ();
   map {mkdir ($_); chdir ($_)} @Dirs;
   Win32::SetCwd($old_dir);
   }

sub _RemoveTree
   {
   my ($Dir) = @_;

   return if (!$Dir || $Dir eq "\\" || $Dir eq "//" || $Dir eq "..");
   opendir (DIR, $Dir);
   my @ChildDirs = readdir(DIR);
   closedir (DIR);
   map {_RemoveTree ("$Dir/$_") if ($_ ne '.' && $_ ne '..')} @ChildDirs;

   rmdir ($Dir) if (-d $Dir);
   unlink ($Dir) if (-f $Dir);
   }



#sub DumpHistories
#   {
#   my ($Histories) = @_;
#   print "====== History List in order time order ======\n";
#   map {print join (',', @{$_}) . "\n";} @{$Histories};
#   print "==============================================\n";
#   }

#sub DumpRevisions
#   {
#   my ($Revisions) = @_;
#   my $i = 2;
#   print "================ Revision List ================\n";
#   foreach my $Revision (@{$Revisions})
#      {
#      print "revision $i:\n"; $i++;
#      map {print "   " . join("\t", @{$_}) . "\n";} @{$Revision};
#      }
#   }

#sub Pause
#   {
#   my ($Message) = @_;
#
#   print "$Message\n";
#   <STDIN>;
#   }


