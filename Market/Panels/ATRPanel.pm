package Market::Panels::ATRPanel;
use strict;
use warnings;

# Inicializa panel ATR.
sub new {
    my ( $class, %args ) = @_;
    my $self = { %args, };
    bless $self, $class;
    return $self;
}

sub _init_crosshair {
    my ($self) = @_;

    # Configura crosshair del panel.
}

sub get_y_range {
    my ( $self, $values ) = @_;

    # Calcula rango del ATR visible.
}

sub set_scale {
    my ( $self, $scale ) = @_;

    # Define escala vertical.
}

sub render {
    my ( $self, $canvas, $values, $scale ) = @_;

    # Dibuja línea del ATR.
}

sub render_last_visible_value {
    my ( $self, $canvas ) = @_;

    # Muestra último valor ATR.
}

sub draw_crosshair {
    my ( $self, $x, $y ) = @_;

    # Dibuja crosshair sincronizado.
}
1;
