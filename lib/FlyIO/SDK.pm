use v5.40;
use experimental qw(class try builtin);

=head1 NAME

FlyIO::SDK

=head1 DESCRIPTION

FlyIO::SDK is a Perl SDK for the L<Fly.io|https://fly.io> API.

=head1 SYNOPSIS

    use v5.40;
    use experimental 'class';

    use FlyIO::SDK;

    # Initialize the SDK
    my $sdk = FlyIO::SDK->new(
        api_token => $ENV{FLY_API_TOKEN},
        org_slug  => $ENV{FLY_ORG_SLUG},
        app_name  => 'my-app'
    );

    # Get the Machines API
    my $machines = $sdk->machines();

    # List all machines
    say "=== Listing all machines ===";
    my $all_machines = $machines->list();
    foreach my $machine ( $all_machines->@* ) {
        say "Machine: " . $machine->id . " (" . $machine->state . ")";
        say "Region: " . $machine->region;
        say "IP: " . $machine->private_ip;
        say "---";
    }

    # Create a new machine
    say "\n=== Creating a new machine ===";
    my $new_machine = $machines->create(
        {
            config => {
                image => "registry.fly.io/ubuntu:latest",
                env   => {
                    APP_ENV => "production"
                },
                processes => [],
                services  => [],
                guest     => {
                    cpu_kind  => "shared",
                    cpus      => 1,
                    memory_mb => 256
                }
            }
        }
    );

    say "Created machine: " . $new_machine->id;

    # Wait for machine to start
    say "\n=== Waiting for machine to start ===";
    my $started = $machines->wait( $new_machine->id, 'started', 60 );
    say $started ? "Machine started successfully" : "Machine failed to start";

    # Get specific machine details
    say "\n=== Getting machine details ===";
    my $machine = $machines->get( $new_machine->id );
    my $json    = JSON::PP->new->pretty->convert_blessed;
    say $json->encode( $machine->get_status() );

    # Stop the machine
    say "\n=== Stopping machine ===";
    my $result = $machines->stop( $machine->id );
    say $result->is_success ? "Machine stopped" : "Failed to stop machine";

    # Delete the machine (with force)
    say "\n=== Deleting machine ===";
    $result = $machines->delete( $machine->id, 1 );    # force=true
    say $result->is_success ? "Machine deleted" : "Failed to delete machine";

=cut

my $FLY_API_HOST = $ENV{FLY_API_HOST} // 'api.machines.dev';

=head1 class FlyIO::SDK

The main class for interacting with the Fly.io API.

=cut

class FlyIO::SDK {
    our $VERSION = '0.01';

=over 4

=item C<< new( api_token => $api_token, org_slug => $org_slug, app_name => $app_name ) >>

=cut


    field $app_name :param;
    field $api_token :param = $ENV{FLY_API_TOKEN};
    field $org_slug :param  = $ENV{FLY_ORG_SLUG};

    field $client :param :reader = FlyIO::Client->new(
        api_token => $api_token,
        org_slug  => $org_slug,
    );

=over 4

=item C<api_token>

The API token to use for authentication.

=item C<org_slug> OPTIONAL

The organization slug.

=item C<app_name> OPTIONAL

The app name.

=back

=item C<apps()>

Returns the Apps API.

=cut

    method apps() {
        return FlyIO::API::Apps->new(
            client   => $client,
            org_slug => $org_slug,
        );
    }

=item C<machines()>

Returns the Machines API.


    method machines() {
        return FlyIO::API::Machines->new(
            client   => $client,
            app_name => $app_name
        );
    }

=back
}

=head1 class FlyIO::SDK::Response

The response class for the Fly.io API.

=cut

class FlyIO::SDK::Response {
    use Carp qw(croak);

    field $status :param :reader;
    field $data :param          = {};
    field $error :param :reader = undef;
    field $raw_response :param  = '';

    method is_success() {
        return $status >= 200 && $status < 300;
    }

    method data() {
        croak "Response error: $error" unless $self->is_success;
        return wantarray ? ref $data eq 'ARRAY' ? @$data : %$data : $data;
    }
}

=head1 class FlyIO::Client

The client class for the Fly.io API.

=cut

class FlyIO::Client {
    use HTTP::Tiny;
    use JSON::PP;

    field $api_token :param;
    field $org_slug :param;
    field $base_url :param = "https://$FLY_API_HOST/v1";
    field $http :reader    = HTTP::Tiny->new( agent => 'Fly-Perl-SDK/0.01' );
    field $json :reader    = JSON::PP->new->utf8->convert_blessed;

    ADJUST {
        # Remove trailing slash from base_url if present
        $base_url =~ s{/$}{};
    }

    method request( $method, $endpoint, $data = undef ) {

        # Ensure endpoint starts with /
        $endpoint = "/$endpoint" unless $endpoint =~ m{^/};

        my $url = $base_url . $endpoint;

        # Add org_slug to query if needed
        if ( $method eq 'POST' && $url !~ /\?/ ) {
            $url .= "?org_slug=$org_slug" if $org_slug;
        }

        my $options = {
            headers => {
                'Authorization' => "Bearer $api_token",
            }
        };

        # Set content type and body for POST/PUT requests
        if ($data) {
            $options->{headers}{'Content-Type'} = 'application/json';
            $options->{content} = $json->encode($data);
        }

        my $response = $http->request( $method, $url, $options );

        return $self->_parse_response($response);
    }

    method _parse_response($response) {
        my $content = $response->{content};
        my $data;
        my $error;

        if ($content) {
            try {
                $data = $json->decode($content);
            }
            catch ($e) {
                $error = "Failed to parse JSON: $e";
            };
        }

        if ( !$response->{success} ) {
            $error //= $response->{status} . ' ' . $response->{reason};
        }

        return FlyIO::SDK::Response->new(
            status       => $response->{status},
            data         => $data,
            error        => $error,
            raw_response => $response
        );
    }
}

=head1 class FlyIO::API::Apps

A class representing the apps API.

=cut

class FlyIO::API::Apps {
    use Carp    qw(croak);
    use builtin qw(false);

=over 4

=item C<< new( client => $client, org_slug => $org_slug, app_name => $app_name, network => $network ) >>

=cut

    field $client :param :reader;
    field $app_name :param = undef;
    field $org_slug :param = undef;
    field $network :param  = undef;

=over 4

=item C<client>

A FlyIO::Client object.

=item C<org_slug> OPTIONAL

The organization slug.

=item C<app_name> OPTIONAL

The app name.

=item C<network> OPTIONAL

The network name.

=back

=item C<list()>

Returns a list of apps as FlyIO::Objects::App objects.

=cut

    method list() {
        croak 'Missing org slug' unless $org_slug;

        my $response = $client->request( 'GET', "/apps?org_slug=$org_slug" );
        try {
            return [ map { FlyIO::Objects::App->new(%$_) }
                  @{ $response->data } ];
        }
        catch ($e) {
            croak "Failed to list machines: $e";
        }
    }

=item C<get($app_name)>

Returns a specific app as a FlyIO::Objects::App object.

=cut

    method get( $app_name = $app_name ) {
        croak 'Missing app name' unless $app_name;

        my $response = $client->request( 'GET', "/apps/$app_name" );
        try {
            return FlyIO::Objects::App->new( $response->data );
        }
        catch ($e) {
            croak "Failed to get app: $e";
        }
    }

=item C<create( $config = { name => $app_name } )>

Returns a new app as a FlyIO::Objects::App object.

=cut

    method create( $config = { name => $app_name } ) {
        croak "Missing app name" unless $config->{app_name};

        $config->{org_slug} = $org_slug if $org_slug;
        $config->{network}  = $network  if $network;

        my $response = $client->request( 'POST', "/apps", $config );
        try {
            return FlyIO::Objects::App->new( $response->data );
        }
        catch ($e) {
            croak "Failed to create app: $e";
        }
    }

=item C<delete( $app_name = $app_name, $force = false )>

Returns a deleted app as a FlyIO::Objects::App object.

=cut

    method delete( $app_name = $app_name, $force = false ) {
        croak 'Missing app name' unless $app_name;

        my $response = $client->request( 'DELETE',
            "/apps/$app_name" . ( $force ? "?force=true" : '' ) );
        try {
            return FlyIO::Objects::App->new( $response->data );
        }
        catch ($e) {
            croak "Failed to update app: $e";
        }
    }

=back

=cut

}

class FlyIO::Objects::App {
    field $id :param :reader;
    field $name :param :reader;
    field $state :param :reader;
    field $organization :param :reader = {};

    method is_pending() {
        return $state eq 'pending';
    }

    method TO_JSON() {
        return {
            id           => $id,
            name         => $name,
            state        => $state,
            organization => $organization
        };
    }
}

class FlyIO::API::Machines {
    use Carp qw(croak);

    field $client :param :reader;
    field $app_name :param;

    # List all machines for an app
    method list() {
        my $response = $client->request( 'GET', "/apps/$app_name/machines" );

        try {
            return [ map { FlyIO::Objects::Machine->new(%$_) }
                  @{ $response->data } ];
        }
        catch ($e) {
            croak "Failed to list machines: $e";
        }
    }

    # Get a specific machine
    method get($machine_id) {
        my $response =
          $client->request( 'GET', "/apps/$app_name/machines/$machine_id" );

        try {
            return FlyIO::Objects::Machine->new( $response->data );
        }
        catch ($e) {
            croak "Failed to get machine: $e";
        }
    }

    # Create a new machine
    method create($config) {
        my $response =
          $client->request( 'POST', "/apps/$app_name/machines", $config );

        try {
            return FlyIO::Objects::Machine->new( $response->data );
        }
        catch ($e) {
            croak "Failed to create machine: $e";
        }
    }

    # Update a machine
    method update( $machine_id, $config ) {
        my $response = $client->request( 'POST',
            "/apps/$app_name/machines/$machine_id", $config );

        try {
            return FlyIO::Objects::Machine->new( $response->data );
        }
        catch ($e) {
            croak "Failed to update machine: $e";
        }
    }

    # Delete a machine
    method delete( $machine_id, $force = 0 ) {
        my $endpoint = "/apps/$app_name/machines/$machine_id";
        $endpoint .= "?force=true" if $force;

        return $client->request( 'DELETE', $endpoint );
    }

    # Start a machine
    method start($machine_id) {
        return $client->request( 'POST',
            "/apps/$app_name/machines/$machine_id/start" );
    }

    # Stop a machine
    method stop( $machine_id, $timeout = 30 ) {
        return $client->request(
            'POST',
            "/apps/$app_name/machines/$machine_id/stop",
            {
                timeout => $timeout
            }
        );
    }

    # Wait for machine state
    method wait( $machine_id, $state = 'started', $timeout = 60 ) {
        my $response = $client->request( 'GET',
"/apps/$app_name/machines/$machine_id/wait?state=$state&timeout=$timeout"
        );

        return $response->is_success;
    }

    # Get machine metadata
    method metadata($machine_id) {
        my $response = $client->request( 'GET',
            "/apps/$app_name/machines/$machine_id/metadata" );

        try {
            return $response->data;
        }
        catch ($e) {
            croak "Failed to get machine metadata: $e";
        }
    }

    # Update machine metadata
    method update_metadata( $machine_id, $metadata ) {
        return $client->request( 'POST',
            "/apps/$app_name/machines/$machine_id/metadata", $metadata );
    }
}

class FlyIO::Objects::Machine {

    field $id :param :reader          = undef;    # instance id
    field $name :param :reader        = undef;
    field $state :param :reader       = undef;
    field $region :param :reader      = undef;
    field $private_ip :param :reader  = undef;
    field $config :param :reader      = undef;
    field $created_at :param :reader  = undef;
    field $updated_at :param :reader  = undef;
    field $image_ref :param :reader   = undef;
    field $checks :param :reader      = undef;
    field $events :param :reader      = undef;
    field $host_status :param :reader = undef;

    # Convenience methods
    method is_running() {
        return $state eq 'started';
    }

    method is_stopped() {
        return $state eq 'stopped';
    }

    method get_status() {
        return {
            id         => $id,
            name       => $name,
            state      => $state,
            region     => $region,
            created_at => $created_at,
            updated_at => $updated_at
        };
    }

    # Convert to JSON-friendly format
    method TO_JSON() {
        return {
            id          => $id,
            name        => $name,
            state       => $state,
            region      => $region,
            config      => $config,
            created_at  => $created_at,
            updated_at  => $updated_at,
            host_status => $host_status
        };
    }
}

class FlyIO::API::Tokens {
    field $client :param;

    method create() {
        my $response = $client->request( 'POST', "/v1/tokens/oidc" );
        try {
            return $response->data;
        }
        catch ($e) {
            croak "Failed to create token: $e";
        }
    }
}
__END__

=head1 FlyIO::Objects::App

Methods for interacting with apps.

=head2 METHODS

=over 4

=item C<new( id => $id, name => $name, state => $state, organization => $organization )>

=over 4

=item C<id>

The app ID.

=item C<name>

The app name.

=item C<state>

The app state.

=item C<organization>

The app organization.

=back

=item C< id(), name(), state(), organization() >

Reader methods for the above fields.

=item C<is_pending()>

Returns true if the app is pending.

=item C<TO_JSON()>

Returns a hash representation of the app.

=back

=head1 FlyIO::API::Machines

A class representing the machines API.

=head2 METHODS

=over 4

=item C<new( client => $client, app_name => $app_name )>

=over 4

=item C<client>

A FlyIO::Client object.

=item C<app_name> OPTIONAL

The app name.

=back
=item C<list()>

Lists all machines.

=item C<get($machine_id)>

Gets a specific machine.

=item C<create($config)>

Creates a new machine.

=head1 FlyIO::API::Tokens

A class representing the tokens API.

=head1 AUTHOR

Chris Prather C<<chris at prather.org>>

