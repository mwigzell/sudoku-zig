#!/usr/bin/env bash
# Usage: run-with-timeout.sh SECONDS command...
set -euo pipefail
limit="${1:?seconds required}"
shift
perl -e '
  my $sec = shift @ARGV;
  $SIG{ALRM} = sub { die "timeout after ${sec}s\n" };
  alarm $sec;
  exec @ARGV or die "exec failed: $!\n";
' "$limit" "$@"
