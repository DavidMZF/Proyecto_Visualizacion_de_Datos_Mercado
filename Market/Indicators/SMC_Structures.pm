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
# modulo reutiliza los swings YA validados por Liquidity.
#
# NOTA FASE 2: La clasificacion de HH/HL/LH/LL se ha desacoplado de la 
# liquidez bruta y ahora consume estrictamente los pivotes confirmados por 
# el indicador ZigZagMTF para aislar la estructura predecible del ruido.
# =============================================================================

use strict;
use warnings;

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        liquidity   => $args{liquidity},          # Indicators::Liquidity (swings para BOS)
        zzmtf       => $args{zzmtf},              # NUEVA DEPENDENCIA: Indicators::ZigZagMTF
        break_mode  => $args{break_mode} // 'close',   # 'close' | 'wick'

        _c      => [],    # velas procesadas
        _events => [],    # eventos BOS / iBOS confirmados

        # Niveles activos (precio) aun no rotos.
        _bos_high  => undef,
        _bos_low   => undef,
        _ibos_high => undef,
        _ibos_low  => undef,

        # Indice del swing que sostiene cada nivel activo.
        _bos_high_index  => undef,
        _bos_low_index   => undef,
        _ibos_high_index => undef,
        _ibos_low_index  => undef,

        # Ultimo swing high/low PRINCIPAL confirmado.
        _principal_high_index => undef,
        _principal_low_index  => undef,

        # Anti-duplicado: ids de swings ya consumidos.
        _seen_swing_id => {},

        # --- NUEVAS VARIABLES PARA ESTRUCTURA ZZMTF (Fase 2) ---
        _swing_labels  => {},
        _seen_pivot_id => {},
        _last_high     => undef,
        _last_low      => undef,
        _bias          => undef,
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
    
    # Reset Estructura ZZMTF
    $self->{_swing_labels}  = {};
    $self->{_seen_pivot_id} = {};
    $self->{_last_high}     = undef;
    $self->{_last_low}      = undef;
    $self->{_bias}          = undef;
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
sub get_events       { return $_[0]->{_events}; }
sub processed_last   { return $#{ $_[0]->{_c} }; }
sub get_swing_labels { return $_[0]->{_swing_labels}; } # NUEVO ACCESOR PARA OVERLAY

# -----------------------------------------------------------------------------
# _process: integra la vela en el indice i = $#_c.
# -----------------------------------------------------------------------------
sub _process {
    my ( $self, $c ) = @_;
    push @{ $self->{_c} }, $c;
    my $i = $#{ $self->{_c} };

    $self->_ingest_new_swings($i);
    $self->_check_break( $i, $c, 'ibos' );
    $self->_check_break( $i, $c, 'bos' );
    
    # NUEVA LLAMADA: Clasificar HH/HL/LH/LL usando exclusivamente el ZZMTF
    $self->_classify_zzmtf_pivots();
}

# -----------------------------------------------------------------------------
# _ingest_new_swings (Mantiene tu lógica original para BOS e iBOS intacta)
# -----------------------------------------------------------------------------
sub _ingest_new_swings {
    my ( $self, $i ) = @_;
    my $liq = $self->{liquidity};
    return unless $liq;

    my $swings = $liq->get_swings;
    return unless $swings && @$swings;

    for my $sw (@$swings) {
        next if $sw->{index} >= $i; 
        next if $self->{_seen_swing_id}{ $sw->{id} }; 
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
# _check_break (Mantiene tu lógica original)
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
        dir       => $dir,          
        index     => $i,            
        origin    => $origin,       
        ts        => $self->{_c}[$i]{ts},
        price     => $price,
        label     => $label,
        confirmed => 1,
    };
}

# -----------------------------------------------------------------------------
# _classify_zzmtf_pivots: Genera las etiquetas HH/HL/LH/LL exclusivamente
# a partir de los pivotes confirmados por el ZigZagMTF.
# -----------------------------------------------------------------------------
sub _classify_zzmtf_pivots {
    my ($self) = @_;
    my $zzmtf = $self->{zzmtf};
    return unless $zzmtf;

    my $pivots = $zzmtf->get_pivots();
    return unless $pivots && @$pivots;

    for my $piv (@$pivots) {
        # Evitar re-procesar pivotes usando el ID propio del ZigZag
        next if $self->{_seen_pivot_id}{ $piv->{id} };
        $self->{_seen_pivot_id}{ $piv->{id} } = 1;

        # Traducir el índice del bloque agregado al índice de la vela de 1 minuto
        my $base_index = $zzmtf->_base_index_for_pivot($piv);

        if ( $piv->{kind} eq 'H' ) {
            my $label;
            if ( !defined $self->{_last_high} ) {
                $label = 'HH';
            } elsif ( $piv->{price} > $self->{_last_high}{price} ) {
                $label = 'HH';
                $self->{_bias} = 'bull'; # Actualizamos tendencia
            } else {
                $label = 'LH';
            }
            
            # Guardar el hash completo para el Overlay
            $self->{_swing_labels}{ $base_index } = { 
                label => $label, 
                price => $piv->{price}, 
                kind  => 'H' 
            };
            
            # Si la tendencia macro es bajista ('bear'), un LH es un máximo válido.
            # Si es alcista, evitamos que un LH (ruido) borre el techo estructural.
            if ( !defined $self->{_bias} || $self->{_bias} ne 'bull' || $label eq 'HH' ) {
                $self->{_last_high} = { index => $base_index, price => $piv->{price} };
            }
        }
        else {   # 'L' (Valle)
            my $label;
            if ( !defined $self->{_last_low} ) {
                $label = 'LL';
            } elsif ( $piv->{price} > $self->{_last_low}{price} ) {
                $label = 'HL';
            } else {
                $label = 'LL';
                $self->{_bias} = 'bear'; # Actualizamos tendencia
            }
            
            $self->{_swing_labels}{ $base_index } = { 
                label => $label, 
                price => $piv->{price}, 
                kind  => 'L' 
            };
            
            if ( !defined $self->{_bias} || $self->{_bias} ne 'bear' || $label eq 'LL' ) {
                $self->{_last_low} = { index => $base_index, price => $piv->{price} };
            }
        }
    }
}

1;