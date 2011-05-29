package Courriel;

use strict;
use warnings;
use namespace::autoclean;

use Courriel::ContentType;
use Courriel::Headers;
use Courriel::Part::Multipart;
use Courriel::Part::Single;
use Courriel::Types qw( Bool Headers StringRef );
use Email::MIME::ContentType qw( parse_content_type );
use MooseX::Params::Validate qw( validated_list );

use Moose;

with 'Courriel::Role::HasParts', 'Courriel::Role::HasContentType';

has headers => (
    is       => 'ro',
    isa      => Headers,
    required => 1,
);

override BUILDARGS => sub {
    my $class = shift;

    my $p = super();

    if ( exists $p->{part} ) {
        my $part = delete $p->{part};

        $p->{parts} = [$part]
            unless exists $p->{parts};
    }

    return $p;
};

sub _build_content_type {
    my $self = shift;

    if ( @{$self->parts()}==1) {
        return $self->parts()->[0]->content_type()
    }
    else {
        return 'multipart/mixed';
    }
}

# from Email::Simple
my $LINE_SEP_RE = qr/\x0a\x0d|\x0d\x0a|\x0a|\x0d/;

sub parse {
    my $class = shift;

    my ( $headers, @parts ) = $class->_parse( @_, top_level => 1 );

    return $class->new(
        headers => $headers,
        parts   => \@parts,
    );
}

sub _parse {
    my $class = shift;
    my ( $text, $top_level ) = validated_list(
        \@_,
        text      => { isa => StringRef, coerce  => 1 },
        top_level => { isa => Bool,      default => 0 },
    );

    my ( $line_sep, $sep_idx, $headers ) = $class->_parse_headers($text);

    substr( ${$text}, 0, $sep_idx ) = q{};

    my @parts = $class->_parse_parts( $text, $headers, $top_level );

    return ( $headers, @parts );
}

sub _parse_headers {
    my $class = shift;
    my $text  = shift;

    my $header_text;
    my $sep_idx;
    my $line_sep;

    if ( ${$text} =~ /(.+?)($LINE_SEP_RE)\2/s ) {
        $header_text = $1 . $2;
        $sep_idx     = ( length $header_text ) + ( length $2 );
        $line_sep    = $2;
    }
    else {
        die
            'The text you passed to parse() does not appear to be a valid email.';
    }

    # Need to quote class name or else this perl sees this as
    # Courriel::Headers() because of the Headers type constraint.
    my $headers = 'Courriel::Headers'->parse(
        text     => \$header_text,
        line_sep => $line_sep,
    );

    return ( $line_sep, $sep_idx, $headers );
}

sub _parse_parts {
    my $class     = shift;
    my $text      = shift;
    my $headers   = shift;
    my $top_level = shift;

    my @ct = $headers->get('Content-Type');
    if ( @ct > 1 ) {
        die 'This email defines more than one content-type header.';
    }

    my $parsed_ct = parse_content_type( $ct[0] // 'text/plain' );

    my $ct = 'Courriel::ContentType'->new(
        mime_type => "$parsed_ct->{discrete}/$parsed_ct->{composite}",
        (
            $parsed_ct->{attributes}{charset}
            ? ( charset => $parsed_ct->{attributes}{charset} )
            : ()
        ),
        attributes => $parsed_ct->{attributes},
    );

    # The headers for the message as a whole should not be considered the
    # headers for the top-level part.
    $headers = 'Courriel::Headers'->new() if $top_level;

    if ( $ct->mime_type() !~ /^multipart/ ) {
        return Courriel::Part::Single->new(
            content_type => $ct,
            headers      => $headers,
            raw_content  => $text,
        );
    }

    my $boundary = $ct->{attributes}{boundary}
        // die q{The message's mime type claims this is a multipart message (}
        . $ct->mime_type()
        . q{) but it does not specify a boundary.};

    ${$text} =~ /
                (?<preamble>.*?)
                (?:
                    ^--\Q$boundary\E\s*
                    (?<part>.+)?
                )+
                ^--\Q$boundary\E--\s*
                (?<epilogue>.*?)
                /sx;

    return map {
        my ( undef, $part ) = $class->_parse( \$_ );
        $part;
    } @{ $-{part} };
}

__PACKAGE__->meta()->make_immutable();

1;
