package Market::MarketData;
use strict;
use warnings;

# Inicializa almacenamiento de datos OHLC.
sub new {
    my ($class) = @_;
    my $self = { data => {}, };
    bless $self, $class;
    return $self;
}

sub get_data {
    my ($self) = @_;

    # Devuelve la estructura completa de datos. Acceso general.
}

sub add_candle {
    my ( $self, $candle ) = @_;

    # Agrega una vela nueva. Entrada principal de datos.
}

sub build_tf_candles {
    my ( $self, $tf ) = @_;

    # Construye velas en una temporalidad específica. Agregación (ej: 1m → 5m).
}

sub build_timeframes {
    my ($self) = @_;

    # Construye todas las temporalidades disponibles. Preprocesamiento completo.
}

sub set_timeframe {
    my ( $self, $tf ) = @_;

    # Selecciona la temporalidad activa. Afecta qué datos se usan.
}

sub _active_array {
    my ($self) = @_;

    # Devuelve el array activo según timeframe. Abstracción interna clave.
}

sub get_slice {
    my ( $self, $start, $end ) = @_;

    # Devuelve un subconjunto de velas. Base para indicadores y render.
}

sub get_candle {
    my ( $self, $index ) = @_;

    # Obtiene una vela por índice.
}

sub size {
    my ($self) = @_;

    # Número total de velas.
}

sub last_candle {
    my ($self) = @_;

    # Devuelve la última vela.
}

sub last_index {
    my ($self) = @_;

    # Devuelve índice de la última vela.
}

sub get_timestamp {
    my ( $self, $index ) = @_;

    # Obtiene timestamp de una vela.
}

sub merge_delta_row {
    my ( $self, $row ) = @_;

    # Actualiza o inserta datos incrementales. Manejo de streaming.
}

sub compute_time_anchors {
    my ($self) = @_;

    # Calcula puntos clave de tiempo. Usado para ejes o etiquetas.
}

1;
