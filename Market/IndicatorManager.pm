package Market::IndicatorManager;
use strict;
use warnings;

# ─── Constructor ──────────────────────────────────────────────────────────────
# Inicializa el contenedor de indicadores.
# Estructura interna:
#   indicators => {
#     'ATR' => objeto Market::Indicators::ATR,
#     ...    => cualquier indicador futuro
#   }
sub new {
    my ($class) = @_;
    my $self = {
        indicators => {},
    };
    bless $self, $class;
    return $self;
}

# ─── register ─────────────────────────────────────────────────────────────────
# Registra un indicador bajo un nombre clave.
# Permite agregar nuevos indicadores sin modificar este módulo (extensibilidad).
# Input:  $name      => string identificador (ej: 'ATR')
#         $indicator => objeto con métodos update_last, get_values, reset
# Output: ninguno
sub register {
    my ($self, $name, $indicator) = @_;
    $self->{indicators}{$name} = $indicator;
}

# ─── update_last ──────────────────────────────────────────────────────────────
# Actualiza todos los indicadores registrados con el estado actual del mercado.
# Cálculo incremental: cada indicador decide internamente desde dónde recalcular.
# Input:  $market_data => objeto Market::MarketData
# Output: ninguno
sub update_last {
    my ($self, $market_data) = @_;
    for my $name (keys %{ $self->{indicators} }) {
        $self->{indicators}{$name}->update_last($market_data);
    }
}

# ─── get ──────────────────────────────────────────────────────────────────────
# Obtiene el arrayref completo de valores de un indicador.
# Input:  $name => string identificador
# Output: arrayref de valores (puede contener undefs al inicio)
#         undef si el indicador no existe
sub get {
    my ($self, $name) = @_;
    return undef unless exists $self->{indicators}{$name};
    return $self->{indicators}{$name}->get_values();
}

# ─── slice_array ──────────────────────────────────────────────────────────────
# Devuelve una porción de valores de un indicador sincronizada con la ventana visible.
# Fundamental para que los paneles solo rendericen lo que está en pantalla.
# Input:  $name  => string identificador
#         $start => índice inicial (entero)
#         $end   => índice final inclusive (entero)
# Output: arrayref con los valores del rango, o arrayref vacío si no existe
sub slice_array {
    my ($self, $name, $start, $end) = @_;
    my $values = $self->get($name);
    return [] unless defined $values;

    my $max = $#$values;
    $start  = 0    if $start < 0;
    $end    = $max if $end   > $max;

    # Rango inválido
    return [] if $start > $end || $start > $max;

    return [ @{$values}[$start..$end] ];
}

# ─── reset_all ────────────────────────────────────────────────────────────────
# Reinicia todos los indicadores registrados.
# Debe llamarse al cambiar de timeframe, ya que los datos cambian completamente.
# Input:  ninguno
# Output: ninguno
sub reset_all {
    my ($self) = @_;
    for my $name (keys %{ $self->{indicators} }) {
        $self->{indicators}{$name}->reset();
    }
}

1;