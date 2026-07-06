package Market::Indicators::SMC_Structures;

# =============================================================================
# Market::Indicators::SMC_Structures
#
# Calculo de BOS (Break of Structure) e iBOS (Internal Break of Structure)
# a partir de los Swing Points ya confirmados por Indicators/Liquidity.pm
# (filtrados por ATR + desplazamiento). SOLO calcula: el dibujo es de
# Overlays/SMC_Structures.pm.
#
# A diferencia de un BOS "clasico" que recalcula sus propios pivotes con una
# ventana fractal fija (length_bos / length_ibos sobre precio crudo), este
# modulo reutiliza los swings YA validados por Liquidity (que aplican el
# filtro de volatilidad ATR y el filtro de desplazamiento/momentum). Esto
# evita procesar dos veces la deteccion de pivotes y mantiene una sola
# fuente de verdad para "que es un swing valido" en todo el sistema.
#
# -----------------------------------------------------------------------------
# NIVELES Y ESTADO (Memoria del Mercado)
#
#   $bos_high / $bos_low   : precio del ultimo Swing High / Low PRINCIPAL
#                             (estructura mayor) aun no roto.
#   $ibos_high / $ibos_low : precio del ultimo Swing High / Low INTERNO
#                             (subestructura) aun no roto.
#
#   "Principal" vs "interno" se distingue por MAGNITUD del swing: un swing
#   es principal si su rango de precio (contra el swing opuesto mas
#   reciente) es >= al de los ultimos N swings del mismo tipo (el swing
#   mas extremo reciente marca estructura mayor); cualquier swing menor
#   que quede dentro de ese rango es subestructura (interno). En terminos
#   practicos: el swing MAS RECIENTE de cada tipo es candidato a
#   $bos_high/$bos_low; los swings intermedios que aparecen mientras ese
#   nivel no se ha roto se tratan como $ibos_high/$ibos_low.
#
# -----------------------------------------------------------------------------
# DETECCION DE QUIEBRE (BOS / iBOS)
#
#   $break_mode = 'close' (por defecto) o 'wick':
#     'close': ruptura alcista si close > nivel; ruptura bajista si close < nivel.
#     'wick' : ruptura alcista si high  > nivel; ruptura bajista si low   < nivel.
#
#   BOS  (estructura principal):
#     - Ruptura alcista de $bos_high -> evento { type=>'BOS', dir=>'up' }.
#       $bos_high se invalida (undef); se vuelve a armar con el siguiente
#       Swing High confirmado.
#     - Ruptura bajista de $bos_low  -> evento { type=>'BOS', dir=>'down' }.
#       $bos_low se invalida (undef); idem con el siguiente Swing Low.
#     - Regla de reinicio: al confirmarse un BOS (cualquier direccion),
#       TODOS los niveles iBOS activos se invalidan de inmediato (undef),
#       forzando a recalcular la subestructura desde el nuevo punto de
#       partida macro.
#
#   iBOS (subestructura): misma logica que BOS pero sobre $ibos_high /
#     $ibos_low. No dispara reinicio de nada mas.
#
# -----------------------------------------------------------------------------
# PREVENCION DE REPETICIONES
#
#   Un nivel roto queda "mitigado": se invalida (undef) de inmediato y NO
#   vuelve a evaluarse hasta que nazca un nuevo pivote intermedio que lo
#   reemplace. No hay reintento sobre el mismo precio en velas consecutivas.
# =============================================================================

use strict;
use warnings;

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        liquidity   => $args{liquidity},          # Indicators::Liquidity (swings)
        break_mode  => $args{break_mode} // 'close',   # 'close' | 'wick'

        _c      => [],    # velas procesadas
        _events => [],    # eventos BOS / iBOS confirmados

        # Niveles activos (precio) aun no rotos. undef = sin nivel vigente.
        _bos_high  => undef,
        _bos_low   => undef,
        _ibos_high => undef,
        _ibos_low  => undef,

        # Indice del swing que sostiene cada nivel activo (para la linea del
        # overlay, del pivote de origen a la vela de ruptura).
        _bos_high_index  => undef,
        _bos_low_index   => undef,
        _ibos_high_index => undef,
        _ibos_low_index  => undef,

        # Ultimo swing high/low PRINCIPAL confirmado (referencia de
        # magnitud: el mas reciente de cada tipo define bos_high/bos_low;
        # cualquier swing del mismo tipo que aparezca despues, mientras ese
        # nivel principal sigue sin romperse, es subestructura -> ibos).
        _principal_high_index => undef,
        _principal_low_index  => undef,

        # Anti-duplicado: ids de swings ya consumidos (ya se uso su precio
        # para fijar bos_high/bos_low/ibos_high/ibos_low al menos una vez).
        _seen_swing_id => {},
    };
    bless $self, $class;
    return $self;
}

sub get_values { return []; }

sub reset {
    my ($self) = @_;
    $self->{_c}      = [];
    $self->{_events} = [];
    $self->{_bos_high}  = undef;
    $self->{_bos_low}   = undef;
    $self->{_ibos_high} = undef;
    $self->{_ibos_low}  = undef;
    $self->{_bos_high_index}  = undef;
    $self->{_bos_low_index}   = undef;
    $self->{_ibos_high_index} = undef;
    $self->{_ibos_low_index}  = undef;
    $self->{_principal_high_index} = undef;
    $self->{_principal_low_index}  = undef;
    $self->{_seen_swing_id} = {};
}

sub update_at_index {
    my ( $self, $md, $idx ) = @_;
    my $c = $md->get_candle($idx);
    return unless defined $c;
    $self->_process($c);
}

sub update_last {
    my ( $self, $md ) = @_;
    my $c = $md->last_candle;
    return unless defined $c;
    $self->_process($c);
}

# Accesores de solo lectura para el Overlay.
sub get_events      { return $_[0]->{_events}; }
sub processed_last  { return $#{ $_[0]->{_c} }; }

# -----------------------------------------------------------------------------
# _process: integra la vela en el indice i = $#_c.
#   1. Incorpora los swings nuevos que Liquidity ya confirmo (pueden llegar
#      con retraso respecto al indice actual: fractal_n + v_desp velas).
#   2. Evalua ruptura de iBOS primero (subestructura, mas frecuente).
#   3. Evalua ruptura de BOS (estructura principal). Si ocurre, invalida
#      todo iBOS activo (regla de reinicio).
# -----------------------------------------------------------------------------
sub _process {
    my ( $self, $c ) = @_;
    push @{ $self->{_c} }, $c;
    my $i = $#{ $self->{_c} };

    $self->_ingest_new_swings($i);
    $self->_check_break( $i, $c, 'ibos' );
    $self->_check_break( $i, $c, 'bos' );
}

# -----------------------------------------------------------------------------
# _ingest_new_swings: recorre los swings confirmados por Liquidity que aun
# no se han incorporado (anti-duplicado via _seen_swing_id) y que preceden
# a la vela actual. Por cada swing nuevo:
#   - Si no hay bos_high/bos_low vigente de ese tipo -> se convierte en
#     PRINCIPAL (bos_*), estableciendo tambien el punto de referencia de
#     magnitud (_principal_*_index).
#   - Si YA hay un nivel principal vigente de ese tipo -> este swing es
#     subestructura: alimenta ibos_high/ibos_low (se sobreescribe con el
#     mas reciente, ya que el iBOS relevante es siempre el ultimo pivote
#     intermedio antes de la ruptura).
# -----------------------------------------------------------------------------
sub _ingest_new_swings {
    my ( $self, $i ) = @_;
    my $liq = $self->{liquidity};
    return unless $liq;

    my $swings = $liq->get_swings;
    return unless $swings && @$swings;

    for my $sw (@$swings) {
        next if $sw->{index} >= $i;                       # aun no disponible cronologicamente
        next if $self->{_seen_swing_id}{ $sw->{id} };      # ya incorporado
        $self->{_seen_swing_id}{ $sw->{id} } = 1;

        if ( $sw->{kind} eq 'H' ) {
            if ( !defined $self->{_bos_high} ) {
                $self->{_bos_high}       = $sw->{price};
                $self->{_bos_high_index} = $sw->{index};
                $self->{_principal_high_index} = $sw->{index};
            }
            else {
                $self->{_ibos_high}       = $sw->{price};
                $self->{_ibos_high_index} = $sw->{index};
            }
        }
        else {   # 'L'
            if ( !defined $self->{_bos_low} ) {
                $self->{_bos_low}       = $sw->{price};
                $self->{_bos_low_index} = $sw->{index};
                $self->{_principal_low_index} = $sw->{index};
            }
            else {
                $self->{_ibos_low}       = $sw->{price};
                $self->{_ibos_low_index} = $sw->{index};
            }
        }
    }
}

# -----------------------------------------------------------------------------
# _check_break: evalua ruptura alcista/bajista para 'bos' o 'ibos' segun
# $break_mode ('close' exige cierre de cuerpo; 'wick' acepta mecha).
# Emite a lo sumo un evento por vela y por scope (prioriza alcista).
# -----------------------------------------------------------------------------
sub _check_break {
    my ( $self, $i, $c, $scope ) = @_;

    my $high_key       = $scope eq 'bos' ? '_bos_high'       : '_ibos_high';
    my $low_key        = $scope eq 'bos' ? '_bos_low'        : '_ibos_low';
    my $high_index_key = $scope eq 'bos' ? '_bos_high_index' : '_ibos_high_index';
    my $low_index_key  = $scope eq 'bos' ? '_bos_low_index'  : '_ibos_low_index';

    my $up_break =
        defined $self->{$high_key}
        && ( ( $self->{break_mode} eq 'wick' ) ? $c->{high} : $c->{close} ) > $self->{$high_key};

    if ($up_break) {
        $self->_emit( $scope, 'up', $i, $self->{$high_key}, $self->{$high_index_key} );
        $self->{$high_key}       = undef;
        $self->{$high_index_key} = undef;
        $self->_reset_ibos_on_bos() if $scope eq 'bos';
        return;
    }

    my $down_break =
        defined $self->{$low_key}
        && ( ( $self->{break_mode} eq 'wick' ) ? $c->{low} : $c->{close} ) < $self->{$low_key};

    if ($down_break) {
        $self->_emit( $scope, 'down', $i, $self->{$low_key}, $self->{$low_index_key} );
        $self->{$low_key}       = undef;
        $self->{$low_index_key} = undef;
        $self->_reset_ibos_on_bos() if $scope eq 'bos';
        return;
    }
}

# -----------------------------------------------------------------------------
# _reset_ibos_on_bos: regla de reinicio (punto 5 de la especificacion). Al
# confirmarse un BOS principal, toda subestructura iBOS activa deja de ser
# valida: el proximo swing intermedio que aparezca reconstruye ibos desde
# cero contra el nuevo nivel principal vigente.
# -----------------------------------------------------------------------------
sub _reset_ibos_on_bos {
    my ($self) = @_;
    $self->{_ibos_high}       = undef;
    $self->{_ibos_low}        = undef;
    $self->{_ibos_high_index} = undef;
    $self->{_ibos_low_index}  = undef;
}

sub _emit {
    my ( $self, $scope, $dir, $i, $price, $origin ) = @_;
    my $label = ( $scope eq 'bos' ) ? 'BOS' : 'iBOS';
    push @{ $self->{_events} }, {
        type      => $scope eq 'bos' ? 'BOS' : 'iBOS',
        scope     => $scope eq 'bos' ? 'external' : 'internal',
        dir       => $dir,          # up | down
        index     => $i,            # vela de ruptura
        origin    => $origin,       # indice del swing roto (inicio de la linea)
        ts        => $self->{_c}[$i]{ts},
        price     => $price,
        label     => $label,
        confirmed => 1,
    };
}

1;