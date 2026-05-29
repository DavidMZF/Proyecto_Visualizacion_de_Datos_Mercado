package Market::Indicators::ATR;
use strict;
use warnings;

#Inicializa ATR con su período.
sub new {
    my ( $class, $period ) = @_;
    my $self = {
        period => $period,
        values => [],
    };
    bless $self, $class;
    return $self;
}

sub update_last {
    my ( $self, $market_data ) = @_;

    # Actualiza el ATR con la última vela. Implementa cálculo incremental.
}

sub get_values {
    my ($self) = @_;

    # Devuelve serie completa del ATR.
}

sub reset {
    my ($self) = @_;

    # Reinicia el indicador.
}

1;
