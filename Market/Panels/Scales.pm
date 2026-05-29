package Market::Panels::Scales;
use strict;
use warnings;

# Inicializa sistema de escalas.
sub new {
    my ( $class, %args ) = @_;
    my $self = { %args, };
    bless $self, $class;
    return $self;
}

sub index_to_x {
    my ( $self, $index ) = @_;

    # Convierte índice → coordenada X.
}

sub x_to_index {
    my ( $self, $x ) = @_;

    # Convierte X → índice entero.
}

sub x_to_index_float {
    my ( $self, $x ) = @_;

    # Convierte X → índice continuo. Más precisión para interacción.
}

sub index_to_center_x {
    my ( $self, $index ) = @_;

    # Devuelve centro de una vela en X.
}

sub value_to_y {
    my ( $self, $value ) = @_;

    # Convierte valor (precio/indicador) → Y.
}

sub y_to_value {
    my ( $self, $y ) = @_;

    # Convierte Y → valor.
}

sub _draw_y_scale {
    my ( $self, $canvas ) = @_;

    # Dibuja escala vertical (precios/valores).
}
1;