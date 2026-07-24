package Market::Indicators::TrendLineChannel;

# =============================================================================
# Market::Indicators::TrendLineChannel
#
# Modelo de datos del canal de tendencia (Trend Line Channel), estilo
# TradingView. Fase 1: solo modo MANUAL (dibujo por el usuario con 3 clics).
#
#   Clic 1 (origen)     -> punto A (idx, price)
#   Clic 2 (horizontal) -> punto B (idx, price): define la PENDIENTE de la
#                          linea media (A -> B). Se previsualiza con una
#                          linea recta A->cursor mientras se mueve el mouse.
#   Clic 3 (vertical)   -> define el ANCHO del canal (desviacion en precio
#                          respecto a la linea media, medida en el punto C).
#                          Se previsualiza con las dos bandas mientras se
#                          mueve el mouse verticalmente.
#
# Este modulo NO dibuja nada (eso es el Overlay). Solo guarda el estado
# geometrico y expone metodos para construir/editar el canal:
#   - start_at(idx, price)          -> arranca la construccion (clic 1)
#   - set_point_b(idx, price)       -> fija clic 2 (pendiente)
#   - set_deviation(idx, price)     -> fija clic 3 (ancho) y CIERRA el canal
#   - cancel_pending                -> aborta una construccion a medias
#
# Edicion posterior (drag):
#   - move_point_a(idx, price)
#   - move_point_b(idx, price)
#   - set_deviation_value(dev)      -> ancho absoluto (drag directo de banda)
#   - translate(d_idx, d_price)     -> mover todo el canal (arrastre del centro)
#
# Contrato minimo esperado por el Overlay (Fase 1, un solo canal manual):
#   - get_channel() -> undef | { ax, ay, bx, by, deviation, upper_off,
#                                 lower_off, slope, intercept }
#     (ax/ay = punto A; bx/by = punto B; idx en floats permitidos para que
#     el overlay pueda dibujar con precision sub-vela si se desea)
#   - get_pending() -> estado a medias durante la construccion (para que el
#     overlay dibuje el preview): { stage => 1|2, ax, ay, bx?, by? }
# =============================================================================

use strict;
use warnings;

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        mode => $args{mode} // 'manual',   # unico modo soportado por ahora

        # Estado de construccion en curso (mientras el usuario hace clic 1/2/3)
        _stage => 0,     # 0 = inactivo, 1 = esperando punto B, 2 = esperando desviacion
        _ax    => undef,
        _ay    => undef,
        _bx    => undef,
        _by    => undef,

        # Canal ya confirmado (clic 3 hecho)
        _channel => undef,   # { ax, ay, bx, by, deviation }
    };
    bless $self, $class;
    return $self;
}

# -----------------------------------------------------------------------------
# reset: contrato generico de indicadores del proyecto.
# -----------------------------------------------------------------------------
sub reset {
    my ($self) = @_;
    $self->{_stage}   = 0;
    $self->{_ax}      = undef;
    $self->{_ay}      = undef;
    $self->{_bx}       = undef;
    $self->{_by}       = undef;
    $self->{_channel} = undef;
}

# -----------------------------------------------------------------------------
# Contrato IndicatorManager (no aplica calculo por vela aqui: es 100% manual).
# -----------------------------------------------------------------------------
sub update_at_index { return; }
sub update_last      { return; }
sub get_values        { return []; }

# -----------------------------------------------------------------------------
# Construccion interactiva (clics)
# -----------------------------------------------------------------------------

# Clic 1: origen del canal. Reinicia cualquier construccion/canal previo.
sub start_at {
    my ( $self, $idx, $price ) = @_;
    return unless defined $idx && defined $price;
    $self->{_stage}   = 1;
    $self->{_ax}      = $idx;
    $self->{_ay}      = $price;
    $self->{_bx}      = undef;
    $self->{_by}       = undef;
    $self->{_channel} = undef;
}

# Clic 2: punto que define la pendiente de la linea media (A -> B).
sub set_point_b {
    my ( $self, $idx, $price ) = @_;
    return unless $self->{_stage} == 1;
    return unless defined $idx && defined $price;
    $self->{_bx}    = $idx;
    $self->{_by}    = $price;
    $self->{_stage} = 2;
}

# Clic 3: fija el ancho del canal (desviacion vertical) y lo confirma.
# $idx/$price = posicion del cursor en el momento del clic; la desviacion
# se calcula como la distancia vertical (en precio) entre ese punto y la
# linea media evaluada en su mismo indice.
sub set_deviation {
    my ( $self, $idx, $price ) = @_;
    return unless $self->{_stage} == 2;
    return unless defined $idx && defined $price;

    my $mid_price_at_idx = $self->_line_price_at( $self->{_ax}, $self->{_ay},
                                                    $self->{_bx}, $self->{_by}, $idx );
    my $deviation = abs( $price - $mid_price_at_idx );
    $deviation = 0.0001 if $deviation <= 0;   # evitar canal de ancho 0

    $self->{_channel} = {
        ax        => $self->{_ax},
        ay        => $self->{_ay},
        bx        => $self->{_bx},
        by        => $self->{_by},
        deviation => $deviation,
    };
    $self->{_stage} = 0;
    $self->{_ax} = $self->{_ay} = $self->{_bx} = $self->{_by} = undef;
}

# Aborta una construccion a medias (ESC). No toca un canal ya confirmado.
sub cancel_pending {
    my ($self) = @_;
    $self->{_stage} = 0;
    $self->{_ax} = $self->{_ay} = $self->{_bx} = $self->{_by} = undef;
}

sub is_building   { return $_[0]->{_stage} > 0; }
sub building_stage { return $_[0]->{_stage}; }

# -----------------------------------------------------------------------------
# Edicion posterior (drag de handles sobre un canal ya confirmado)
# -----------------------------------------------------------------------------

sub move_point_a {
    my ( $self, $idx, $price ) = @_;
    return unless $self->{_channel};
    $self->{_channel}{ax} = $idx;
    $self->{_channel}{ay} = $price;
}

sub move_point_b {
    my ( $self, $idx, $price ) = @_;
    return unless $self->{_channel};
    $self->{_channel}{bx} = $idx;
    $self->{_channel}{by} = $price;
}

# Ajusta el ancho arrastrando directamente una banda: $idx/$price es la
# posicion actual del cursor sobre esa banda.
sub set_deviation_at {
    my ( $self, $idx, $price ) = @_;
    return unless $self->{_channel};
    my $ch = $self->{_channel};
    my $mid_price_at_idx = $self->_line_price_at( $ch->{ax}, $ch->{ay}, $ch->{bx}, $ch->{by}, $idx );
    my $deviation = abs( $price - $mid_price_at_idx );
    $deviation = 0.0001 if $deviation <= 0;
    $ch->{deviation} = $deviation;
}

# Traslada el canal completo (arrastre del centro): desplaza A y B por igual.
sub translate {
    my ( $self, $d_idx, $d_price ) = @_;
    return unless $self->{_channel};
    my $ch = $self->{_channel};
    $ch->{ax} += $d_idx;
    $ch->{ay} += $d_price;
    $ch->{bx} += $d_idx;
    $ch->{by} += $d_price;
}

sub clear_channel {
    my ($self) = @_;
    $self->{_channel} = undef;
}

sub has_channel { return defined $_[0]->{_channel} ? 1 : 0; }

# -----------------------------------------------------------------------------
# Lectura para el Overlay
# -----------------------------------------------------------------------------

sub get_channel {
    my ($self) = @_;
    my $ch = $self->{_channel};
    return undef unless $ch;

    my ( $slope, $intercept ) = $self->_slope_intercept( $ch->{ax}, $ch->{ay}, $ch->{bx}, $ch->{by} );

    return {
        ax        => $ch->{ax},
        ay        => $ch->{ay},
        bx        => $ch->{bx},
        by        => $ch->{by},
        deviation => $ch->{deviation},
        slope     => $slope,
        intercept => $intercept,
        upper_off => $ch->{deviation},
        lower_off => -$ch->{deviation},
    };
}

# Estado a medias, para que el overlay dibuje el preview mientras se
# construye (junto con la posicion actual del cursor, que el overlay ya
# conoce via ChartEngine).
sub get_pending {
    my ($self) = @_;
    return undef unless $self->{_stage} > 0;
    return {
        stage => $self->{_stage},
        ax    => $self->{_ax},
        ay    => $self->{_ay},
        bx    => $self->{_bx},
        by    => $self->{_by},
    };
}

# -----------------------------------------------------------------------------
# Helpers geometricos internos
# -----------------------------------------------------------------------------
sub _slope_intercept {
    my ( $self, $ax, $ay, $bx, $by ) = @_;
    my $dx = $bx - $ax;
    if ( $dx == 0 ) {
        # Segmento vertical degenerado: pendiente 0 para no romper el render.
        return ( 0, $ay );
    }
    my $slope     = ( $by - $ay ) / $dx;
    my $intercept = $ay - $slope * $ax;
    return ( $slope, $intercept );
}

sub _line_price_at {
    my ( $self, $ax, $ay, $bx, $by, $idx ) = @_;
    my ( $slope, $intercept ) = $self->_slope_intercept( $ax, $ay, $bx, $by );
    return $slope * $idx + $intercept;
}

1;