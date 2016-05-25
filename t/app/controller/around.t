use strict;
use warnings;
use Test::More;
use LWP::Protocol::PSGI;

use t::Mock::MapIt;
use FixMyStreet::TestMech;
my $mech = FixMyStreet::TestMech->new;

subtest "check that if no query we get sent back to the homepage" => sub {
    $mech->get_ok('/around');
    is $mech->uri->path, '/', "redirected to '/'";
};

# x,y requests were generated by the old map code. We keep the behavior for
# historic links
subtest "redirect x,y requests to lat/lon (301 - permanent)" => sub {

    FixMyStreet::override_config {
        MAPIT_URL => 'http://mapit.mysociety.org/',
    }, sub {
        $mech->get_ok('/around?x=3281&y=1113');
    };

    # did we redirect to lat,lon?
    is $mech->uri->path, '/around', "still on /around";
    is_deeply { $mech->uri->query_form },
      { lat => 51.499825, lon => -0.140137, zoom => 3 },
      "lat,lon correctly set";

    # was it a 301?
    is $mech->res->code, 200, "got 200 for final destination";
    is $mech->res->previous->code, 301, "got 301 for redirect";

};

# test various locations on inital search box
foreach my $test (
    {
        pc              => '',    #
        errors          => [],
        pc_alternatives => [],
    },
    {
        pc              => 'xxxxxxxxxxxxxxxxxxxxxxxxxxx',
        errors          => ['Sorry, we could not find that location.'],
        pc_alternatives => [],
    },
    {
        pc => 'Glenthorpe Ct, Katy, TX 77494, USA',
        errors =>
          ['Sorry, we could not find that location.'],
        pc_alternatives => [],
    },
  )
{
    subtest "test bad pc value '$test->{pc}'" => sub {
        $mech->get_ok('/');
        FixMyStreet::override_config {
            GEOCODER => '',
        }, sub {
            $mech->submit_form_ok( { with_fields => { pc => $test->{pc} } },
                "bad location" );
        };
        is_deeply $mech->page_errors, $test->{errors},
          "expected errors for pc '$test->{pc}'";
        is_deeply $mech->pc_alternatives, $test->{pc_alternatives},
          "expected alternatives for pc '$test->{pc}'";
    };
}

# check that exact queries result in the correct lat,lng
foreach my $test (
    {
        pc        => 'SW1A 1AA',
        latitude  => '51.5',
        longitude => '-2.1',
    },
    {
        pc        => 'TQ 388 773',
        latitude  => '51.478074',
        longitude => '-0.001966',
    },
  )
{
    subtest "check lat/lng for '$test->{pc}'" => sub {
        LWP::Protocol::PSGI->register(t::Mock::MapIt->run_if_script, host => 'mapit.uk');

        $mech->get_ok('/');
        FixMyStreet::override_config {
            ALLOWED_COBRANDS => [ { 'fixmystreet' => '.' } ],
            MAPIT_URL => 'http://mapit.uk/',
        }, sub {
            $mech->submit_form_ok( { with_fields => { pc => $test->{pc} } },
                "good location" );
        };
        is_deeply $mech->page_errors, [], "no errors for pc '$test->{pc}'";
        is_deeply $mech->extract_location, $test,
          "got expected location for pc '$test->{pc}'";
    };
}

subtest 'check non public reports are not displayed on around page' => sub {
    my $params = {
        postcode  => 'EH99 1SP',
        latitude  => 55.9519637512,
        longitude => -3.17492254484,
    };
    my @edinburgh_problems =
      $mech->create_problems_for_body( 5, 2651, 'Around page', $params );

    $mech->get_ok('/');
    FixMyStreet::override_config {
        ALLOWED_COBRANDS => [ { 'fixmystreet' => '.' } ],
        MAPIT_URL => 'http://mapit.mysociety.org/',
    }, sub {
        $mech->submit_form_ok( { with_fields => { pc => 'EH99 1SP' } },
            "good location" );
    };
    $mech->content_contains( 'Around page Test 3 for 2651',
        'problem to be marked non public visible' );

    my $private = $edinburgh_problems[2];
    ok $private->update( { non_public => 1 } ), 'problem marked non public';

    $mech->get_ok('/');
    $mech->submit_form_ok( { with_fields => { pc => 'EH99 1SP' } },
        "good location" );
    $mech->content_lacks( 'Around page Test 3 for 2651',
        'problem marked non public is not visible' );
};


subtest 'check category and status filtering works on /ajax' => sub {
    my $categories = [ 'Pothole', 'Vegetation', 'Flytipping' ];
    my $params = {
        postcode  => 'OX1 1ND',
        latitude  => 51.7435918829363,
        longitude => -1.23201966270446,
    };
    my $bbox = ($params->{longitude} - 0.01) . ',' .  ($params->{latitude} - 0.01)
                . ',' . ($params->{longitude} + 0.01) . ',' .  ($params->{latitude} + 0.01);

    # Create one open and one fixed report in each category
    foreach my $category ( @$categories ) {
        foreach my $state ( 'confirmed', 'fixed' ) {
            my %report_params = (
                %$params,
                category => $category,
                state => $state,
            );
            $mech->create_problems_for_body( 1, 2237, 'Around page', \%report_params );
        }
    }

    my $json = $mech->get_ok_json( '/ajax?bbox=' . $bbox );
    my $pins = $json->{pins};
    is scalar @$pins, 6, 'correct number of reports when no filters';

    $json = $mech->get_ok_json( '/ajax?filter_category=Pothole&bbox=' . $bbox );
    $pins = $json->{pins};
    is scalar @$pins, 2, 'correct number of Pothole reports';

    $json = $mech->get_ok_json( '/ajax?status=open&bbox=' . $bbox );
    $pins = $json->{pins};
    is scalar @$pins, 3, 'correct number of open reports';

    $json = $mech->get_ok_json( '/ajax?status=fixed&filter_category=Vegetation&bbox=' . $bbox );
    $pins = $json->{pins};
    is scalar @$pins, 1, 'correct number of fixed Vegetation reports';
};

done_testing();
