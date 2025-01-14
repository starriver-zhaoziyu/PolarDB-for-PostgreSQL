# Test for recovery targets: name, timestamp, XID
use strict;
use warnings;
use PostgresNode;
use TestLib;
use Test::More tests => 9;

# Create and test a standby from given backup, with a certain recovery target.
# Choose $until_lsn later than the transaction commit that causes the row
# count to reach $num_rows, yet not later than the recovery target.
sub test_recovery_standby
{
	my $test_name       = shift;
	my $node_name       = shift;
	my $node_master     = shift;
	my $recovery_params = shift;
	my $num_rows        = shift;
	my $until_lsn       = shift;

	my $node_standby = get_new_node($node_name, 0);
	$node_standby->init_from_backup($node_master, 'my_backup',
		has_restoring => 1);

	foreach my $param_item (@$recovery_params)
	{
		$node_standby->append_conf('recovery.conf', qq($param_item));
	}

	$node_standby->start;

	# Wait until standby has replayed enough data
	my $caughtup_query =
	  "SELECT '$until_lsn'::pg_lsn <= pg_last_wal_replay_lsn()";
	$node_standby->poll_query_until('postgres', $caughtup_query)
	  or die "Timed out while waiting for standby to catch up";

	# Create some content on master and check its presence in standby
	my $result =
	  $node_standby->safe_psql('postgres', "SELECT count(*) FROM tab_int");
	is($result, qq($num_rows), "check standby content for $test_name");

	# Stop standby node
	$node_standby->teardown_node;

	return;
}

# Initialize master node
my $node_master = get_new_node('master');
$node_master->init(has_archiving => 1, allows_streaming => 1);

# Start it
$node_master->start;

# Create data before taking the backup, aimed at testing
# recovery_target = 'immediate'
$node_master->safe_psql('postgres',
	"CREATE TABLE tab_int AS SELECT generate_series(1,1000) AS a");
my $lsn1 =
  $node_master->safe_psql('postgres', "SELECT pg_current_wal_lsn();");

# Take backup from which all operations will be run
$node_master->backup('my_backup');

# Insert some data with used as a replay reference, with a recovery
# target TXID.
$node_master->safe_psql('postgres',
	"INSERT INTO tab_int VALUES (generate_series(1001,2000))");
my $ret = $node_master->safe_psql('postgres',
	"SELECT pg_current_wal_lsn(), txid_current();");
my ($lsn2, $recovery_txid) = split /\|/, $ret;

# More data, with recovery target timestamp
$node_master->safe_psql('postgres',
	"INSERT INTO tab_int VALUES (generate_series(2001,3000))");
my $lsn3 =
  $node_master->safe_psql('postgres', "SELECT pg_current_wal_lsn();");
my $recovery_time = $node_master->safe_psql('postgres', "SELECT now()");

# Even more data, this time with a recovery target name
$node_master->safe_psql('postgres',
	"INSERT INTO tab_int VALUES (generate_series(3001,4000))");
my $recovery_name = "my_target";
my $lsn4 =
  $node_master->safe_psql('postgres', "SELECT pg_current_wal_lsn();");
$node_master->safe_psql('postgres',
	"SELECT pg_create_restore_point('$recovery_name');");

# And now for a recovery target LSN
$node_master->safe_psql('postgres',
	"INSERT INTO tab_int VALUES (generate_series(4001,5000))");
my $lsn5 = my $recovery_lsn =
  $node_master->safe_psql('postgres', "SELECT pg_current_wal_lsn()");

$node_master->safe_psql('postgres',
	"INSERT INTO tab_int VALUES (generate_series(5001,6000))");

# Force archiving of WAL file
$node_master->safe_psql('postgres', "SELECT pg_switch_wal()");

# Test recovery targets
my @recovery_params = ("recovery_target = 'immediate'");
test_recovery_standby('immediate target',
	'standby_1', $node_master, \@recovery_params, "1000", $lsn1);
@recovery_params = ("recovery_target_xid = '$recovery_txid'");
test_recovery_standby('XID', 'standby_2', $node_master, \@recovery_params,
	"2000", $lsn2);
@recovery_params = ("recovery_target_time = '$recovery_time'");
test_recovery_standby('time', 'standby_3', $node_master, \@recovery_params,
	"3000", $lsn3);
@recovery_params = ("recovery_target_name = '$recovery_name'");
test_recovery_standby('name', 'standby_4', $node_master, \@recovery_params,
	"4000", $lsn4);
@recovery_params = ("recovery_target_lsn = '$recovery_lsn'");
test_recovery_standby('LSN', 'standby_5', $node_master, \@recovery_params,
	"5000", $lsn5);

# Multiple targets
# Last entry has priority (note that an array respects the order of items
# not hashes).
@recovery_params = (
	"recovery_target_name = '$recovery_name'",
	"recovery_target_xid  = '$recovery_txid'",
	"recovery_target_time = '$recovery_time'");
test_recovery_standby('name + XID + time',
	'standby_6', $node_master, \@recovery_params, "3000", $lsn3);
@recovery_params = (
	"recovery_target_time = '$recovery_time'",
	"recovery_target_name = '$recovery_name'",
	"recovery_target_xid  = '$recovery_txid'");
test_recovery_standby('time + name + XID',
	'standby_7', $node_master, \@recovery_params, "2000", $lsn2);
@recovery_params = (
	"recovery_target_xid  = '$recovery_txid'",
	"recovery_target_time = '$recovery_time'",
	"recovery_target_name = '$recovery_name'");
test_recovery_standby('XID + time + name',
	'standby_8', $node_master, \@recovery_params, "4000", $lsn4);
@recovery_params = (
	"recovery_target_xid  = '$recovery_txid'",
	"recovery_target_time = '$recovery_time'",
	"recovery_target_name = '$recovery_name'",
	"recovery_target_lsn = '$recovery_lsn'",);
test_recovery_standby('XID + time + name + LSN',
	'standby_9', $node_master, \@recovery_params, "5000", $lsn5);
