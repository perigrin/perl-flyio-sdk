#! /usr/bin/env perl
use v5.40;
use experimental qw(defer);
use lib 'lib';

use Test2::V0;
use FlyIO::SDK;

{

    local $ENV{FLY_API_TOKEN} = 'test_token';
    local $ENV{FLY_ORG_SLUG}  = 'test_org';

    package Mock::HTTP::Tiny {
        sub new { bless {}, shift }

        our @responses;
        sub response { shift @responses }

        sub request {
            my ( $self, $method, $url, $options ) = @_;

            # Record the request for verification
            push @Mock::HTTP::Tiny::requests, [ $method, $url, $options ];

            return $self->response();
        }
    }

    no warnings 'redefine';
    local *HTTP::Tiny::new = sub { Mock::HTTP::Tiny->new() };

    subtest 'Client initialization' => sub {
        my $client = FlyIO::Client->new(
            api_token => 'test_token',
            org_slug  => 'test_org'
        );

        ok $client, 'Client created';
        is $client->http->isa('Mock::HTTP::Tiny'), 1,
          'Mock HTTP client attached';
    };

    subtest 'Request handling' => sub {
        my $client = FlyIO::Client->new(
            api_token => 'test_token',
            org_slug  => 'test_org',
            base_url  => 'https://api.example.com'
        );

        # Clear previous requests
        @Mock::HTTP::Tiny::requests = ();

        # Mock successful response
        @Mock::HTTP::Tiny::responses = (
            {
                success => 1,
                status  => 200,
                content => '{"data": "test"}'
            }
        );

        my $response = $client->request( 'GET', '/test' );

        # Verify request was made correctly
        is scalar(@Mock::HTTP::Tiny::requests), 1, 'One request made';
        my ( $method, $url, $options ) = @{ $Mock::HTTP::Tiny::requests[0] };

        is $method, 'GET',                          'Correct method';
        is $url,    'https://api.example.com/test', 'Correct URL';
        like $options->{headers}{Authorization}, qr/Bearer test_token/,
          'Bearer token set';

        # Verify response
        ok $response->isa('FlyIO::SDK::Response'), 'Response object returned';
        is $response->status, 200, 'Correct status';
        is $response->data, { data => 'test' }, 'Correct data';
    };

    subtest 'POST with data' => sub {
        use JSON::PP qw(decode_json);

        my $client = FlyIO::Client->new(
            api_token => 'test_token',
            org_slug  => 'test_org',
            base_url  => 'https://api.example.com'
        );

        @Mock::HTTP::Tiny::requests  = ();
        @Mock::HTTP::Tiny::responses = (
            {
                success => 1,
                status  => 201,
                content => '{"created": true}'
            }
        );

        my $data     = { key => 'value' };
        my $response = $client->request( 'POST', '/create', $data );

        my ( $method, $url, $options ) = @{ $Mock::HTTP::Tiny::requests[0] };

        is $method, 'POST', 'POST method';
        like $url, qr/org_slug=test_org/, 'org_slug added';
        is $options->{headers}{'Content-Type'}, 'application/json',
          'Content-Type set';
        is decode_json( $options->{content} ), $data, 'JSON encoded data';
    };

    subtest 'Error handling' => sub {
        my $client = FlyIO::Client->new(
            api_token => 'test_token',
            org_slug  => 'test_org'
        );

        # Mock error response
        @Mock::HTTP::Tiny::responses = (
            {
                success => 0,
                status  => 404,
                reason  => 'Not Found',
                content => '{"error": "Resource not found"}'
            }
        );

        my $response = $client->request( 'GET', '/nonexistent' );

        ok !$response->is_success, 'Response indicates failure';
        is $response->status, 404, 'Correct error status';
        like $response->error, qr/404 Not Found/,
          'Error message includes status';
    };

}

{

    local $ENV{FLY_API_TOKEN} = 'test_token';
    local $ENV{FLY_ORG_SLUG}  = 'test_org';

    subtest 'Successful response' => sub {
        my $response = FlyIO::SDK::Response->new(
            status       => 200,
            data         => { test => 'data' },
            raw_response => {}
        );

        ok $response->is_success, 'Success status';
        is $response->data, { test => 'data' }, 'Data retrieved';
    };

    subtest 'Error response' => sub {
        my $response = FlyIO::SDK::Response->new(
            status       => 400,
            data         => {},
            error        => 'Bad Request',
            raw_response => {}
        );

        ok !$response->is_success, 'Not success';

        like dies { $response->data }, qr/Response error: Bad Request/,
          'data croaks on error';
    };

}

{
    subtest 'Machine object creation' => sub {
        my $data = {
            id         => 'machine123',
            name       => 'test-machine',
            state      => 'started',
            region     => 'sea',
            private_ip => '192.168.1.100',
            created_at => '2023-01-01T00:00:00Z',
        };

        my $machine = FlyIO::Objects::Machine->new(%$data);

        is $machine->id,    'machine123', 'ID correct';
        is $machine->state, 'started',    'State correct';
        ok $machine->is_running,  'is_running true for started state';
        ok !$machine->is_stopped, 'is_stopped false for started state';
    };

    subtest 'Machine state methods' => sub {
        my $stopped = FlyIO::Objects::Machine->new( state => 'stopped' );
        ok !$stopped->is_running, 'Stopped machine not running';
        ok $stopped->is_stopped,  'Stopped machine is stopped';

        my $destroyed = FlyIO::Objects::Machine->new( state => 'destroyed' );
        ok !$destroyed->is_running, 'Destroyed machine not running';
        ok !$destroyed->is_stopped, 'Destroyed machine not stopped';
    };

    subtest 'Machine status method' => sub {
        my $machine = FlyIO::Objects::Machine->new(
            id         => 'test123',
            name       => 'test',
            state      => 'running',
            region     => 'sjc',
            created_at => '2023-01-01',
            updated_at => '2023-01-02'
        );

        my $status = $machine->get_status;

        is $status->{id},        'test123', 'Status ID correct';
        is $status->{state},     'running', 'Status state correct';
        is scalar keys %$status, 6, 'Status has correct number of fields';
    };

    subtest 'JSON serialization' => sub {
        my $machine = FlyIO::Objects::Machine->new(
            id     => 'json123',
            name   => 'json-test',
            state  => 'running',
            region => 'dfw'
        );

        my $json = $machine->TO_JSON;
        is $json->{id}, 'json123', 'JSON ID correct';
        ok exists $json->{state},        'JSON has state';
        ok !exists $json->{instance_id}, 'JSON omits undefined fields';
    };

}

{
    # Mock client for testing
    package Mock::Client {
        sub new { bless {}, shift }

        our @responses;
        our @requests;

        sub next_request()  { shift @requests }
        sub next_response() { shift @responses }

        sub request ( $self, $method, $endpoint, $data = {} ) {
            push @Mock::Client::requests, [ $method, $endpoint, $data ];
            return next_response();
        }
    }

    subtest 'Machine listing' => sub {
        my $machines = FlyIO::API::Machines->new(
            client   => Mock::Client->new(),
            app_name => 'test-app'
        );

        # Mock successful list response
        @Mock::Client::responses = (
            FlyIO::SDK::Response->new(
                status => 200,
                data   => [
                    { id => 'm1', state => 'running' },
                    { id => 'm2', state => 'stopped' }
                ],
                raw_response => {}
            )
        );

        my $result = $machines->list();

        is ref($result),        'ARRAY',   'Returns array ref';
        is scalar(@$result),    2,         'Two machines returned';
        is $result->[0]->id,    'm1',      'First machine correct';
        is $result->[1]->state, 'stopped', 'Second machine state correct';

        my ( $method, $endpoint ) = Mock::Client::next_request()->@*;
        is $method,   'GET',                     'GET method used';
        is $endpoint, '/apps/test-app/machines', 'Correct endpoint';
    };

    subtest 'Machine creation' => sub {
        my $machines = FlyIO::API::Machines->new(
            client   => Mock::Client->new(),
            app_name => 'test-app'
        );

        my $config = {
            config => {
                image => 'ubuntu:latest',
                guest => { cpus => 1, memory_mb => 512 }
            }
        };

        @Mock::Client::responses = (
            FlyIO::SDK::Response->new(
                status       => 201,
                data         => { id => 'new-machine', state => 'created' },
                raw_response => {}
            )
        );

        my $result = $machines->create($config);

        is $result->id, 'new-machine', 'New machine ID correct';

        my ( $method, $endpoint, $data ) = Mock::Client::next_request()->@*;
        is $method,   'POST',                    'POST method used';
        is $endpoint, '/apps/test-app/machines', 'Correct endpoint';
        is $data,     $config,                   'Config passed correctly';
    };

    subtest 'Machine operations' => sub {
        my $machines = FlyIO::API::Machines->new(
            client   => Mock::Client->new(),
            app_name => 'test-app'
        );

        @Mock::Client::requests = ();

        # Mock responses for various operations
        @Mock::Client::responses = (
            FlyIO::SDK::Response->new(
                status       => 200,
                data         => {},
                raw_response => {}
            ),    # start
            FlyIO::SDK::Response->new(
                status       => 200,
                data         => {},
                raw_response => {}
            ),    # stop
            FlyIO::SDK::Response->new(
                status       => 200,
                data         => {},
                raw_response => {}
            ),    # wait
            FlyIO::SDK::Response->new(
                status       => 200,
                data         => {},
                raw_response => {}
            ),    # delete
        );

        # Test start
        $machines->start('machine123');
        is $Mock::Client::requests[0][0], 'POST', 'Start uses POST';
        like $Mock::Client::requests[0][1], qr/machine123\/start$/,
          'Start endpoint correct';

        # Test stop with timeout
        $machines->stop( 'machine123', 60 );
        is $Mock::Client::requests[1][0], 'POST', 'Stop uses POST';
        like $Mock::Client::requests[1][1], qr/machine123\/stop$/,
          'Stop endpoint correct';
        is $Mock::Client::requests[1][2]{timeout}, 60,
          'Timeout parameter passed';

        # Test wait
        $machines->wait( 'machine123', 'stopped', 30 );
        is $Mock::Client::requests[2][0], 'GET', 'Wait uses GET';
        like $Mock::Client::requests[2][1], qr/state=stopped/,
          'Wait state parameter';
        like $Mock::Client::requests[2][1], qr/timeout=30/,
          'Wait timeout parameter';

        # Test delete with force
        $machines->delete( 'machine123', 1 );
        is $Mock::Client::requests[3][0], 'DELETE', 'Delete uses DELETE';
        like $Mock::Client::requests[3][1], qr/force=true/,
          'Force parameter added';
    };

}

{
    subtest 'SDK initialization' => sub {
        my $sdk = FlyIO::SDK->new(
            api_token => 'test_token',
            org_slug  => 'test_org',
            app_name  => 'test_app'
        );

        ok $sdk, 'SDK created';
        is $sdk->machines->isa('FlyIO::API::Machines'), 1,
          'Machines API accessible';
    };

    subtest 'Client injection' => sub {
        my $mock_client = Mock::Client->new();

        my $sdk = FlyIO::SDK->new(
            client   => $mock_client,
            app_name => 'test_app'
        );

        is $sdk->machines->client, $mock_client, 'Custom client used';
    };

}

done_testing();
