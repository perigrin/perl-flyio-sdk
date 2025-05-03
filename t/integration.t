#! /usr/bin/env perl
use v5.40;
use experimental qw(defer);
use lib 'lib';

use Test2::V0;
use FlyIO::SDK;

# Skip integration tests if no API token provided
my $api_token = $ENV{FLY_API_TOKEN};
my $app_name  = $ENV{FLY_TEST_APP}
  || die "FLY_TEST_APP environment variable required";

{
    use JSON::PP;
    use File::Temp qw(tempfile);

  SKIP: {
        skip_all "No FLY_API_TOKEN provided" unless $api_token;

        my $sdk = FlyIO::SDK->new(
            api_token => $api_token,
            app_name  => $app_name
        );

        my $machines = $sdk->machines();

        subtest 'Machine lifecycle' => sub {

            # Create a machine
            my $machine = $machines->create(
                {
                    config => {
                        image => "registry.fly.io/alpine:latest",
                        env   => { TEST => "1" },
                        guest => {
                            cpu_kind  => "shared",
                            cpus      => 1,
                            memory_mb => 256
                        }
                    }
                }
            );

            ok $machine, 'Machine created';
            is $machine->state, 'created', 'Initial state is created';

            # Start the machine
            my $start_response = $machines->start( $machine->id );
            ok $start_response->is_success, 'Machine started';

            # Wait for started state
            my $started = $machines->wait( $machine->id, 'started', 120 );
            ok $started, 'Machine reached started state';

            # Get updated machine info
            my $updated = $machines->get( $machine->id );
            is $updated->state, 'started', 'Machine is running';

            # Stop the machine
            my $stop_response = $machines->stop( $machine->id );
            ok $stop_response->is_success, 'Machine stopped';

            # Wait for stopped state
            my $stopped = $machines->wait( $machine->id, 'stopped', 120 );
            ok $stopped, 'Machine reached stopped state';

            # Delete the machine
            my $delete_response = $machines->delete( $machine->id, 1 );
            ok $delete_response->is_success, 'Machine deleted';
        };

        subtest 'Machine listing' => sub {
            my $all_machines = $machines->list();

            ok ref($all_machines) eq 'ARRAY', 'Machines list is array';

            foreach my $machine (@$all_machines) {
                ok $machine->isa('FlyIO::Objects::Machine'),
                  'Each item is a Machine object';
                ok $machine->id, 'Each machine has an ID';
            }
        };
    }

}
