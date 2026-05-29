package Market::IndicatorManager;
use strict;
use warnings;

# Inicializa el contenedor de indicadores.
sub new {
    my ($class) = @_;
    my $self = { indicators => {}, };
    bless $self, $class;
    return $self;
}

sub register {
    my ( $self, $name, $indicator ) = @_;

    # Registra un indicador. Permite extensibilidad.
}

sub update_last {
    my ( $self, $market_data ) = @_;

    # Actualiza indicadores con la última vela. Cálculo incremental eficiente.
}

sub get {
    my ( $self, $name ) = @_;

    # Obtiene valores de un indicador.
}

sub slice_array {
    my ( $self, $name, $start, $end ) = @_;

# Devuelve una porción de valores del indicador. Sincronización con ventana visible.
}

sub reset_all {
    my ($self) = @_;

    # Reinicia todos los indicadores. Útil al cambiar timeframe.
}
1;
