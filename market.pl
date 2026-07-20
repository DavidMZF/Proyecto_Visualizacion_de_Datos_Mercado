# =============================================================================
# market.pl
# =============================================================================

use strict;
use warnings;
use FindBin qw($Bin);
use lib $Bin;

use Tk;
use Time::Moment;

use Market::MarketData;
use Market::IndicatorManager;
use Market::Indicators::ATR;
use Market::Panels::Scales;
use Market::Panels::PricePanel;
use Market::Panels::ATRPanel;
use Market::ChartEngine;
use Market::OverlayManager;
use Market::Overlays::DemoOverlay;
use Market::Replay;

# --- Fase 2: motores analiticos y overlays SMC / Liquidez (Tabla 1) ---
use Market::Indicators::Liquidity;
use Market::Indicators::SMC_Structures;
use Market::Overlays::SMC_Structures;
use Market::Overlays::Liquidity;
use Market::Indicators::ZigZagMTF;
use Market::Indicators::ZigZagMTF2;
use Market::Indicators::ZigZagVolumeProfile;
use Market::Indicators::ZigZagVolumeProfile2;
use Market::Overlays::ZigZagMTF;
use Market::Overlays::ZigZagMTF2;
use Market::Overlays::ZigZagVolumeProfile;
use Market::Overlays::ZigZagVolumeProfile2;
use Market::Indicators::AnchoredVolumeProfile;
use Market::Overlays::AnchoredVolumeProfile;

# --- Ronda 2: motor SMC autonomo (sin ZigZag), leg()/trend propios ---
use Market::Indicators::SMC_Structures2;
use Market::Overlays::SMC_Structures2;

# =============================================================================
# VENTANA
# =============================================================================
my $mw = MainWindow->new;
$mw->title('Market Panel');
$mw->resizable(1, 1);
$mw->configure(-background => '#0f131a');

eval { $mw->state('zoomed') };
eval { $mw->attributes('-zoomed', 1) };
$mw->update;

my $WIN_W = $mw->screenwidth;
my $WIN_H = $mw->screenheight;

if ($mw->width < $WIN_W * 0.9) {
    $mw->geometry("${WIN_W}x${WIN_H}+0+0");
    $mw->update;
}

$WIN_W = $mw->width  if $mw->width  > 100;
$WIN_H = $mw->height if $mw->height > 100;

# =============================================================================
# DIMENSIONES
# =============================================================================
my $PRICE_SCALE_W = 90;
my $TF_BAR_H      = 28;
my $ATR_H_MIN     = 60;
my $ATR_H_MAX     = 400;
my $ATR_H         = 140;
my $CANVAS_W      = $WIN_W;

# =============================================================================
# LAYOUT
# =============================================================================
my $tf_frame = $mw->Frame(-background => '#ffffff', -height => $TF_BAR_H)
    ->pack(-fill => 'x', -side => 'top');

my $canvas_price = $mw->Canvas(
    -background         => '#0f131a',
    -bd                 => 0,
    -highlightthickness => 0,
)->pack(-fill => 'both', -expand => 1, -side => 'top');

my $sep_frame = $mw->Frame(
    -background => '#2a3445',
    -height     => 4,
    -cursor     => 'sb_v_double_arrow',
)->pack(-fill => 'x', -side => 'top');

my $canvas_atr = $mw->Canvas(
    -height             => $ATR_H,
    -background         => '#0f131a',
    -bd                 => 0,
    -highlightthickness => 0,
)->pack(-fill => 'x', -side => 'top');

# =============================================================================
# DATOS
# =============================================================================
print "Cargando datos...\n";
my $market = Market::MarketData->new;

my $csv_path;
for my $cand ("$Bin/data/2026_07_13.csv", "$Bin/2026_07_13.csv", "$Bin/../data/2026_07_13.csv") {
    if (-f $cand) { $csv_path = $cand; last; }
}
die "No se encuentra 2026_07_13.csv\n" unless $csv_path;

open my $fh, '<', $csv_path or die "Error abriendo CSV '$csv_path': $!\n";
<$fh>;
my $count = 0;
while (<$fh>) {
    chomp;
    my ($time_str, $open, $high, $low, $close, $volume) = split /,/;
    next unless defined $close && $close ne '';
    my $tm;
    eval { $tm = Time::Moment->from_string($time_str) };
    next if $@;
    $market->add_candle({
        time   => $time_str,
        ts     => $tm->epoch,
        open   => $open  + 0,
        high   => $high  + 0,
        low    => $low   + 0,
        close  => $close + 0,
        volume => $volume + 0,
    });
    $count++;
}
close $fh;

printf "Cargadas %d velas de 1m\n", $count;
$market->build_timeframes;
printf "5m: %d  |  15m: %d\n",
    scalar @{ $market->get_data->{'5m'} },
    scalar @{ $market->get_data->{'15m'} };

# =============================================================================
# INDICADORES
# =============================================================================
my $ind_manager = Market::IndicatorManager->new;

# El ORDEN de registro importa: en cada vela, rebuild/update procesa los
# indicadores en este orden. Liquidity necesita el ATR ya calculado (tolerancia
# EQH/EQL) y SMC_Structures necesita los swings ya confirmados por Liquidity.
my $atr_ind = Market::Indicators::ATR->new(14);

# ATR dedicado para SMC_Structures2: el Pine usa atrLenInp=200 (Advanced
# Settings) tanto para el filtro de volatilidad (OB) como para el umbral
# Equal High/Low (eqThreshInp * atrMeasure). Reutilizar el ATR(14) de
# Liquidity aqui causaba EQH/EQL distintos a los de TradingView.
my $atr200_ind = Market::Indicators::ATR->new(200);

# ZigZag Multi Time Frame (direccion INTERNA): remuestrea a 30min por
# defecto y corre un zigzag clasico por periodo, independiente de ATR.
my $zzmtf_ind = Market::Indicators::ZigZagMTF->new(
    resolution_minutes => 30,   # 15 | 30 | 60
    period             => 2,    # ZigZag Period (estilo ZZMTF)
);

my $liq_expiry = $zzmtf_ind->{resolution_minutes} * 10;

# ZigZag Multi Time Frame v2 (replica fiel Pine ZZMTF con Fibonacci).
# Resolucion configurable en vivo desde la UI (selectbox).
my $zzmtf2_ind = Market::Indicators::ZigZagMTF2->new(
    resolution => '1d',
    period     => 2,
);

# ZigZag Volume Profile (direccion EXTERNA): zigzag de mayor grado sobre la
# temporalidad base, con volume profile + POC por pierna.
my $zzvp_ind = Market::Indicators::ZigZagVolumeProfile->new(
    period       => 8,    # mayor que zzmtf: captura estructura de mayor grado
    bins         => 10,
    max_profiles => 15,
);

my $zzvp2_ind = Market::Indicators::ZigZagVolumeProfile2->new(
    swing_length         => 600,   # sobre velas 1m: ~10h por ventana, zigzag macro
    channel_width_factor => 1,
    atr_period           => 200,
    volume_bin_count     => 5,
    max_profiles         => 15,
);

my $liq_ind = Market::Indicators::Liquidity->new(
    atr        => $atr_ind,
    zzmtf      => $zzmtf_ind,   
    zzvp       => $zzvp_ind,
    fractal_n  => 3,     # N velas a cada lado para fractalidad base
    m_atr      => 1.5,   # multiplicador ATR (filtro 1: volatilidad)
    atr_period => 14,
    v_desp     => 10,    # ventana max. de velas para validar desplazamiento
    u_desp     => 2.0,   # multiplicador ATR de recorrido minimo (filtro 2)
    level_expiry_n => $liq_expiry,
);
# 2. PASO CRÍTICO: Inyectamos la referencia del ZigZag al crear SMC_Structures
my $smc_ind = Market::Indicators::SMC_Structures->new(
    zzmtf      => $zzmtf_ind,
    zzvp       => $zzvp_ind,
    break_mode => 'close',
    max_age    => 50,
);

# --- Ronda 2: motor SMC autonomo, replica fiel del Pine, sin ZigZag ---
my $smc2_ind = Market::Indicators::SMC_Structures2->new(
    atr => $atr200_ind,   # ATR(200), igual que atrLenInp del Pine (Equal H/L, Order Blocks)
);

my $avp_ind = Market::Indicators::AnchoredVolumeProfile->new(
    mode         => 'auto',
    pivot_length => 50,   # ta.pivothigh/low(length,length), igual criterio LuxAlgo
    atr_period   => 50,
    bin_atr_mult => 1.0,
);

$ind_manager->register('atr',       $atr_ind);
$ind_manager->register('atr200',    $atr200_ind);
$ind_manager->register('zzmtf',     $zzmtf_ind); # <-- Sube a 3er lugar
$ind_manager->register('zzmtf2',    $zzmtf2_ind);
$ind_manager->register('zzvp',      $zzvp_ind);
$ind_manager->register('zzvp2',     $zzvp2_ind);
$ind_manager->register('liquidity', $liq_ind);
$ind_manager->register('smc',       $smc_ind);   # <-- Baja a 4to lugar
$ind_manager->register('smc2',      $smc2_ind);
$ind_manager->register('avp',       $avp_ind);

print "Calculando indicadores (ATR, Liquidity, SMC, ZigZag MTF/VP)...\n";
$ind_manager->rebuild_all($market);

my @levels = @{ $liq_ind->get_levels };
my %by_state;
$by_state{ $_->{state} }++ for @levels;
print "Total niveles registrados: ", scalar(@levels), "\n";
print "  por estado: ", join(", ", map { "$_=$by_state{$_}" } sort keys %by_state), "\n";

my %by_class;
$by_class{ $_->{classification} // "none" }++ for @levels;
print "  por clasificacion: ", join(", ", map { "$_=$by_class{$_}" } sort keys %by_class), "\n";

printf "ATR: %d  |  swings: %d  |  eventos liq: %d  |  eventos BOS/iBOS: %d  |  pivotes ZZMTF: %d  |  piernas ZZVP: %d\n",
    scalar @{ $ind_manager->get('atr') },
    scalar @{ $liq_ind->get_swings },
    scalar @{ $liq_ind->get_events },
    scalar @{ $smc_ind->get_events },
    scalar @{ $zzmtf_ind->get_pivots },
    scalar @{ $zzvp_ind->get_profiles };

printf "SMC2 (motor autonomo): eventos BOS/CHoCH: %d  |  FVGs: %d  |  EQH/EQL: %d  |  OB swing: %d  |  OB internal: %d\n",
    scalar @{ $smc2_ind->get_events },
    scalar @{ $smc2_ind->get_fvgs },
    scalar @{ $smc2_ind->get_eq_events },
    scalar @{ $smc2_ind->get_swing_order_blocks },
    scalar @{ $smc2_ind->get_internal_order_blocks };

# =============================================================================
# OVERLAYS — gestor + overlays reales SMC y Liquidez (Tabla 1, Fase 2)
# Cada overlay solo DIBUJA estructuras ya calculadas por su indicador fuente
# (separacion estricta calculo/render). Nacen OCULTOS: el usuario decide que
# activar de forma independiente desde el menu de herramientas.
# =============================================================================
my $overlay_mgr = Market::OverlayManager->new;
my $smc_overlay   = Market::Overlays::SMC_Structures->new( source => $smc_ind );
my $smc2_overlay  = Market::Overlays::SMC_Structures2->new( source => $smc2_ind );
my $liq_overlay   = Market::Overlays::Liquidity->new( source => $liq_ind, swing_source => $zzmtf_ind );
my $zzmtf_overlay = Market::Overlays::ZigZagMTF->new( source => $zzmtf_ind );
my $zzmtf2_overlay = Market::Overlays::ZigZagMTF2->new( source => $zzmtf2_ind );
$zzmtf2_overlay->set_flag('show_zigzag', 0);
$zzmtf2_overlay->set_flag('show_fibo',   0);
my $zzvp_overlay  = Market::Overlays::ZigZagVolumeProfile->new( source => $zzvp_ind );
my $zzvp2_overlay = Market::Overlays::ZigZagVolumeProfile2->new(
    source              => $zzvp2_ind,
    show_zigzag         => 1,
    show_channel        => 0,   # lineas guia paralelas (ruido tipo abanico)
    show_volume_profile => 0,   # barras de volumen por nivel + etiquetas %
    show_poc            => 0,
);
my $avp_overlay = Market::Overlays::AnchoredVolumeProfile->new( source => $avp_ind );

$overlay_mgr->register('smc',       $smc_overlay, visible => 0);
$overlay_mgr->register('smc2',      $smc2_overlay, visible => 0);
$overlay_mgr->register('liquidity', $liq_overlay, visible => 0);
$overlay_mgr->register('zzmtf',     $zzmtf_overlay, visible => 0);
$overlay_mgr->register('zzmtf2',    $zzmtf2_overlay, visible => 0);
$overlay_mgr->register('zzvp',      $zzvp_overlay, visible => 0);
$overlay_mgr->register('zzvp2',     $zzvp2_overlay, visible => 0);
$overlay_mgr->register('avp',       $avp_overlay, visible => 0);

# =============================================================================
# PANELES Y MOTOR
# =============================================================================
my $price_panel = Market::Panels::PricePanel->new(
    canvas        => $canvas_price,
    price_scale_w => $PRICE_SCALE_W,
);
my $atr_panel = Market::Panels::ATRPanel->new(
    canvas        => $canvas_atr,
    price_scale_w => $PRICE_SCALE_W,
);

my $engine = Market::ChartEngine->new(
    market         => $market,
    indicators     => $ind_manager,
    overlays       => $overlay_mgr,
    canvas_price   => $canvas_price,
    canvas_atr     => $canvas_atr,
    price_panel    => $price_panel,
    atr_panel      => $atr_panel,
    canvas_w       => $CANVAS_W,
    canvas_price_h => 0,
    canvas_atr_h   => $ATR_H,
);

# =============================================================================
# REPLAY (Etapa 3, Fase 2)
# Los widgets referenciados en on_change se declaran aqui pero se crean
# mas abajo, en la barra $tf_frame -- mismo patron de closures que
# ya usa este archivo para sincronizar $mode_btn/$mode_btn_atr.
# =============================================================================
my ( $replay_status_lbl, $btn_replay_play, $btn_replay_pause,
     $btn_replay_step_fwd, $btn_replay_step_back, $btn_replay_fast,
     $btn_replay_exit );

my $replay;
my $_replay_was_active = 0;   # para detectar la transicion inactivo->activo/activo->inactivo
$replay = Market::Replay->new(
    market     => $market,
    indicators => $ind_manager,
    schedule   => sub { $canvas_price->after(@_); },
    on_change  => sub {
        my $active = $replay->is_active;

        if ( $active && !$_replay_was_active ) {
            # Recien arranco el replay: posicionar con margen de 2 velas
            # en blanco a la derecha (efecto "tiempo real").
            $engine->position_replay_pointer;
        } elsif ( !$active && $_replay_was_active ) {
            # Se salio del replay: volver al comportamiento normal EN VIVO.
            $engine->follow_replay_pointer;
        } else {
            # Paso normal (forward/backward/play/pause): NO tocar la
            # camara, solo redibujar para que la vela nueva entre en
            # el lienzo ya posicionado por el usuario.
            $engine->request_render;
        }
        $_replay_was_active = $active;

        my $playing = $replay->is_playing;

        if ($replay_status_lbl) {
            my $text = !$active
                ? 'EN VIVO (replay inactivo)'
                : sprintf(
                    'REPLAY %s | %s',
                    Time::Moment->from_epoch($replay->current_ts)
                        ->with_offset_same_instant(-300)->strftime('%Y-%m-%d %H:%M:%S'),
                    ($playing ? ($replay->is_fast ? 'FAST FORWARD' : 'PLAY') : 'PAUSADO'),
                );
            $replay_status_lbl->configure(-text => $text);
        }

        for my $pair (
            [ $btn_replay_play,       $active ],
            [ $btn_replay_pause,      $active && $playing ],
            [ $btn_replay_step_fwd,   $active && !$playing ],
            [ $btn_replay_step_back,  $active && !$playing ],
            [ $btn_replay_fast,       $active ],
            [ $btn_replay_exit,       $active ],
        ) {
            my ($btn, $enabled) = @$pair;
            next unless $btn;
            $btn->configure(-state => $enabled ? 'normal' : 'disabled');
        }
    },
);

# =============================================================================
# TOOLBAR — se crea ANTES de registrar callbacks para que los botones existan
# =============================================================================
my %bs = (
    -background       => '#ffffff',
    -foreground       => '#1a1f29',
    -activebackground => '#e0e4ea',
    -activeforeground => '#000000',
    -relief           => 'flat',
    -bd               => 0,
    -font             => 'TkDefaultFont 9',
    -padx             => 5,
    -pady             => 3,
);

my $toolbar_left = $tf_frame->Frame(-background => '#ffffff')
    ->pack(-side => 'left', -fill => 'x');

# --- Boton modo precio ---
my $mode_btn;
$mode_btn = $toolbar_left->Button(%bs,
    -text       => 'Panel:Auto',
    -foreground => '#26a69a',
    -font       => 'TkDefaultFont 9 bold',
    -command    => sub {
        my $is_free = $engine->toggle_free_mode_price;
        # El callback se encarga de actualizar el boton
    },
)->pack(-side => 'left', -padx => 4, -pady => 2);

# --- Boton modo ATR ---
my $mode_btn_atr;
$mode_btn_atr = $toolbar_left->Button(%bs,
    -text       => 'ATR:Auto',
    -foreground => '#26a69a',
    -font       => 'TkDefaultFont 9 bold',
    -command    => sub {
        my $is_free = $engine->toggle_free_mode_atr;
        # El callback se encarga de actualizar el boton
    },
)->pack(-side => 'left', -padx => 4, -pady => 2);

$toolbar_left->Frame(-background => '#2a3445', -width => 1, -height => 16)
    ->pack(-side => 'left', -pady => 5, -padx => 6);

# =============================================================================
# CALLBACKS DE MODO — sincronizan botones con estado interno del engine
# Cualquier cambio de modo (boton, regleta, dbl-clic) actualiza el boton.
# =============================================================================
$engine->set_mode_callbacks(
    sub {   # callback precio
        my ($is_free) = @_;
        $mode_btn->configure(
            -text       => $is_free ? 'Panel:Manual' : 'Panel:Auto',
            -foreground => $is_free ? '#ef5350'  : '#26a69a',
        );
    },
    sub {   # callback ATR
        my ($is_free) = @_;
        $mode_btn_atr->configure(
            -text       => $is_free ? 'ATR:Manual' : 'ATR:Auto',
            -foreground => $is_free ? '#ef5350'    : '#26a69a',
        );
    },
);

# =============================================================================
# TEMPORALIDADES
# =============================================================================
my $active_tf = '1m';
my $tf_lbl = $toolbar_left->Label(%bs,
    -text       => '',
    -foreground => '#4f8cff',
    -font       => 'TkDefaultFont 9 bold',
)->pack(-side => 'left', -padx => 4, -pady => 2);

my %tf_btns;
for my $tf (qw(1m 5m 15m 1h 2h 4h D W)) {
    my $btn = $toolbar_left->Button(%bs,
        -text    => $tf,
        -font    => 'TkDefaultFont 9 bold',
        -command => sub {
            return if $active_tf eq $tf;
            $active_tf = $tf;
            $tf_lbl->configure(-text => $tf);
            for my $k (keys %tf_btns) {
                $tf_btns{$k}->configure(
                    -foreground => ($k eq $tf ? '#4f8cff' : '#1a1f29')
                );
            }
            $engine->set_timeframe($tf);

            # Resetear botones de modo a Auto
            $mode_btn->configure(
                -text       => 'Panel:Auto',
                -foreground => '#26a69a',
            );
            $mode_btn_atr->configure(
                -text       => 'ATR:Auto',
                -foreground => '#26a69a',
            );
        },
    )->pack(-side => 'left', -padx => 1, -pady => 2);
    $tf_btns{$tf} = $btn;
}
$tf_btns{'1m'}->configure(-foreground => '#4f8cff');



# =============================================================================
# CONTROLES DE REPLAY (Etapa 3, Fase 2)
# =============================================================================
$toolbar_left->Frame(-background => '#2a3445', -width => 1, -height => 16)
    ->pack(-side => 'left', -pady => 5, -padx => 6);

my $replay_selected_ts;  # ts de la vela elegida, undef si no hay seleccion

my $replay_date_lbl = $toolbar_left->Label(%bs,
    -text       => '—',
    -foreground => '#ffd700',
    -font       => 'TkFixedFont 9',
)->pack(-side => 'left', -padx => 4);

my $btn_replay_start;
$btn_replay_start = $toolbar_left->Button(%bs,
    -text    => 'Replay',
    -command => sub {
        $engine->set_replay_select_mode(1);
        $btn_replay_start->configure(-foreground => '#ffd700');
        $replay_date_lbl->configure(-text => 'clic en vela...');
    },
)->pack(-side => 'left', -padx => 4, -pady => 2);

$engine->set_replay_click_cb(sub {
    my ($ts) = @_;
    $replay_selected_ts = $ts;
    $btn_replay_start->configure(-foreground => '#1a1f29');
    my $fecha = Time::Moment->from_epoch($ts)
        ->with_offset_same_instant(-300)
        ->strftime('%Y-%m-%d %H:%M');
    $replay_date_lbl->configure(-text => $fecha);
    # Habilitar Play para que el usuario confirme
    $btn_replay_play->configure(-state => 'normal');
});

$toolbar_left->Frame(-background => '#2a3445', -width => 1, -height => 16)
    ->pack(-side => 'left', -pady => 5, -padx => 6);

$btn_replay_step_back = $toolbar_left->Button(%bs,
    -text    => '|< Step',
    -state   => 'disabled',
    -command => sub { $replay->step_backward(1); },
)->pack(-side => 'left', -padx => 1, -pady => 2);

$btn_replay_play = $toolbar_left->Button(%bs,
    -text    => 'Play',
    -state   => 'disabled',
    -command => sub {
        if ( defined $replay_selected_ts && !$replay->is_active ) {
            $replay->start($replay_selected_ts);
        }
        $replay->play if $replay->is_active;
    },
)->pack(-side => 'left', -padx => 1, -pady => 2);

$btn_replay_pause = $toolbar_left->Button(%bs,
    -text    => 'Pause',
    -state   => 'disabled',
    -command => sub { $replay->pause; },
)->pack(-side => 'left', -padx => 1, -pady => 2);

$btn_replay_step_fwd = $toolbar_left->Button(%bs,
    -text    => 'Step >|',
    -state   => 'disabled',
    -command => sub { $replay->step_forward(1); },
)->pack(-side => 'left', -padx => 1, -pady => 2);

$btn_replay_fast = $toolbar_left->Button(%bs,
    -text    => 'Fast Forward >>',
    -state   => 'disabled',
    -command => sub { $replay->fast_forward; },
)->pack(-side => 'left', -padx => 1, -pady => 2);

$toolbar_left->Frame(-background => '#2a3445', -width => 1, -height => 16)
    ->pack(-side => 'left', -pady => 5, -padx => 6);

$btn_replay_exit = $toolbar_left->Button(%bs,
    -text       => 'Exit Replay',
    -foreground => '#ef5350',
    -state      => 'disabled',
    -command    => sub {
        $replay->exit_replay;
        $replay_selected_ts = undef;
        $replay_date_lbl->configure(-text => '—');
    },
)->pack(-side => 'left', -padx => 4, -pady => 2);

$replay_status_lbl = $toolbar_left->Label(%bs,
    -text       => 'EN VIVO (replay inactivo)',
    -foreground => '#1a1f29',
    -font       => 'TkDefaultFont 9 bold',
);
# No se hace pack: el label existe pero no se muestra

# =============================================================================
# BOTON: OPACIDAD DE VELAS (a la derecha del bloque de Replay)
# Atenua visualmente el cuerpo de las velas para que las lineas de
# tendencia / overlays por debajo se aprecien mejor.
# =============================================================================
$toolbar_left->Frame(-background => '#2a3445', -width => 1, -height => 16)
    ->pack(-side => 'left', -pady => 5, -padx => 6);

my $btn_candle_opacity;
$btn_candle_opacity = $toolbar_left->Button(%bs,
    -text    => 'Velas: Opacas',
    -command => sub {
        my $opaque = $engine->{price_panel}->toggle_candle_opacity;
        $btn_candle_opacity->configure(
            -text => $opaque ? 'Velas: Opacas' : 'Velas: Atenuadas',
        );
        $engine->render;
    },
)->pack(-side => 'left', -padx => 4, -pady => 2);

$toolbar_left->Frame(-background => '#2a3445', -width => 1, -height => 16)
    ->pack(-side => 'left', -pady => 5, -padx => 6);

# =============================================================================
# ZIGZAG MTF v2 (con Fibonacci): activar + resolucion (junto a Velas: Opacas)
# =============================================================================
my $zzmtf2_zz_on   = 0;
my $zzmtf2_fibo_on = 0;
my $btn_zzmtf2_zz;
my $btn_zzmtf2_fibo;
$btn_zzmtf2_zz = $toolbar_left->Button(%bs,
    -text       => 'Zigzag: Off',
    -foreground => '#00e676',
    -font       => 'TkDefaultFont 9 bold',
    -command    => sub {
        $zzmtf2_zz_on = !$zzmtf2_zz_on;
        $zzmtf2_overlay->set_flag('show_zigzag', $zzmtf2_zz_on);
        $overlay_mgr->set_visible('zzmtf2', $zzmtf2_zz_on || $zzmtf2_fibo_on);
        $btn_zzmtf2_zz->configure(
            -text => $zzmtf2_zz_on ? 'Zigzag: On' : 'Zigzag: Off',
        );
        $engine->render;
    },
)->pack(-side => 'left', -padx => 4, -pady => 2);

$btn_zzmtf2_fibo = $toolbar_left->Button(%bs,
    -text       => 'Fibonacci: Off',
    -foreground => '#2979ff',
    -font       => 'TkDefaultFont 9 bold',
    -command    => sub {
        $zzmtf2_fibo_on = !$zzmtf2_fibo_on;
        $zzmtf2_overlay->set_flag('show_fibo', $zzmtf2_fibo_on);
        $overlay_mgr->set_visible('zzmtf2', $zzmtf2_zz_on || $zzmtf2_fibo_on);
        $btn_zzmtf2_fibo->configure(
            -text => $zzmtf2_fibo_on ? 'Fibonacci: On' : 'Fibonacci: Off',
        );
        $engine->render;
    },
)->pack(-side => 'left', -padx => 4, -pady => 2);

my @zzmtf2_resolutions = (
    '1min', '3min', '5min', '10min', '15min', '30min', '45min',
    '1h', '2h', '3h', '4h',
    '1d', '1w', '1m',
);
my $zzmtf2_resolution = $zzmtf2_ind->{resolution};

my $zzmtf2_res_popup;
my $zzmtf2_res_btn;
my $close_zzmtf2_popup = sub {
    if ($zzmtf2_res_popup) {
        $zzmtf2_res_popup->grabRelease if Tk::Exists($zzmtf2_res_popup);
        $zzmtf2_res_popup->destroy if Tk::Exists($zzmtf2_res_popup);
        $zzmtf2_res_popup = undef;
    }
};

my $select_zzmtf2_resolution = sub {
    my ($res) = @_;
    $zzmtf2_resolution = $res;
    $zzmtf2_ind->reset;
    $zzmtf2_ind->{resolution} = $zzmtf2_resolution;
    for my $i ( 0 .. $market->size - 1 ) {
        $zzmtf2_ind->update_at_index( $market, $i );
    }
    $zzmtf2_res_btn->configure( -text => $zzmtf2_resolution );
    $engine->render;
    $close_zzmtf2_popup->();
};

$zzmtf2_res_btn = $toolbar_left->Button(%bs,
    -text    => $zzmtf2_resolution,
    -relief  => 'raised',
    -command => sub {
        if ($zzmtf2_res_popup) {
            $close_zzmtf2_popup->();
            return;
        }
        my $x = $zzmtf2_res_btn->rootx;
        my $y = $zzmtf2_res_btn->rooty + $zzmtf2_res_btn->height;

        $zzmtf2_res_popup = $zzmtf2_res_btn->Toplevel(
            -background => '#1a1f29',
        );
        $zzmtf2_res_popup->overrideredirect(1);
        $zzmtf2_res_popup->geometry("+${x}+${y}");
        $zzmtf2_res_popup->transient($mw);

        for my $res (@zzmtf2_resolutions) {
            $zzmtf2_res_popup->Button(
                -text       => $res,
                -background => '#1a1f29', -foreground => '#e8e8e8',
                -activebackground => '#4f8cff', -activeforeground => '#ffffff',
                -relief     => 'flat',
                -font       => 'TkDefaultFont 8',
                -anchor     => 'w',
                -command    => sub { $select_zzmtf2_resolution->($res); },
            )->pack(-fill => 'x');
        }

        # Asegurar que la ventana esta mapeada antes de pedir foco/grab,
        # y usar grab para que los clicks no "atraviesen" a widgets de abajo.
        $zzmtf2_res_popup->update;
        $zzmtf2_res_popup->grab;
        $zzmtf2_res_popup->focusForce;
        $zzmtf2_res_popup->bind('<FocusOut>', sub {
            # FocusOut tambien se dispara al hacer click en un boton hijo
            # (otro widget); solo cerrar si el foco realmente salio
            # de toda la jerarquia del popup.
            $zzmtf2_res_popup->after(1, sub {
                return unless $zzmtf2_res_popup;
                my $focused = $zzmtf2_res_popup->focusCurrent;
                unless ( $focused && Tk::Exists($focused)
                    && "$focused" =~ /^\Q$zzmtf2_res_popup\E/ ) {
                    $close_zzmtf2_popup->();
                }
            });
        });
    },
)->pack(-side => 'left', -padx => 4, -pady => 2);

{
    my $drag_y_start = undef;
    my $drag_atr_h   = undef;

    $sep_frame->bind('<ButtonPress-1>', sub {
        $drag_y_start = $_[0]->XEvent->Y;
        $drag_atr_h   = $canvas_atr->height;
    });

    $sep_frame->bind('<B1-Motion>', sub {
        return unless defined $drag_y_start;
        my $dy    = $drag_y_start - $_[0]->XEvent->Y;
        my $new_h = $drag_atr_h + $dy;
        $new_h = $ATR_H_MIN if $new_h < $ATR_H_MIN;
        $new_h = $ATR_H_MAX if $new_h > $ATR_H_MAX;

        $canvas_atr->configure(-height => $new_h);
        $engine->resize_panels(
            $canvas_price->width,
            $canvas_price->height - ($new_h - $drag_atr_h),
            $new_h,
        );
    });

    $sep_frame->bind('<ButtonRelease-1>', sub {
        $drag_y_start = undef;
        $drag_atr_h   = undef;
    });

    $sep_frame->bind('<Double-Button-1>', sub {
        $canvas_atr->configure(-height => 140);
        $mw->update;
        $engine->resize_panels(
            $canvas_price->width,
            $canvas_price->height,
            140,
        );
    });
}

# =============================================================================
# MENU DE HERRAMIENTAS / OVERLAYS (Fase 2)
# Cada herramienta tiene su PROPIO estado de activacion: marcar una opcion
# NUNCA activa las demas. La visibilidad de un overlay completo = (alguna de
# sus sub-opciones activa). El menu SOLO administra estados y dispara render;
# no calcula ni dibuja directamente.
# =============================================================================
my $BAR_BG   = '#ffffff';
my $PANEL_BG = '#ffffff';

my %BBS = (
    -background       => $BAR_BG,
    -activebackground => '#e0e4ea',
    -activeforeground => '#000000',
    -foreground       => '#1a1f29',
    -relief           => 'flat',
    -bd               => 0,
    -font             => 'TkDefaultFont 9',
    -padx             => 5,
    -pady             => 2,
);

# --- Fila "Herramientas:" con el toggle del panel ---
my $tools_outer = $mw->Frame(-background => $BAR_BG);
$tools_outer->pack(-side => 'top', -fill => 'x', -before => $canvas_price);

my $tools_canvas = $tools_outer->Canvas(
    -background => $BAR_BG, -highlightthickness => 0,
)->pack(-side => 'top', -fill => 'x', -expand => 1);

my $tools_hscroll = $tools_outer->Scrollbar(
    -orient => 'horizontal', -command => ['xview', $tools_canvas],
)->pack(-side => 'top', -fill => 'x');
$tools_canvas->configure(-xscrollcommand => ['set', $tools_hscroll]);

my $tools_bar = $tools_canvas->Frame(-background => $BAR_BG);
$tools_canvas->createWindow(0, 0, -anchor => 'nw', -window => $tools_bar);

$tools_bar->bind('<Configure>', sub {
    $tools_canvas->configure(
        -scrollregion => [ $tools_canvas->bbox('all') ],
        -height       => $tools_bar->reqheight,
    );
});


# --- Helpers de construccion del menu ---
my $make_col = sub {
    my ($title, $color) = @_;
    my $col = $tools_bar->Frame(-background => $BAR_BG);
    $col->pack(-side => 'left', -anchor => 'w', -padx => 6, -pady => 2);
    $col->Label(-text => $title, -background => $BAR_BG, -foreground => $color,
        -font => 'TkDefaultFont 9 bold')->pack(-side => 'left', -padx => 4);
    return $col;
};
my $make_chk = sub {
    my ($parent, $text, $varref, $cmd, $disabled) = @_;
    my $cb = $parent->Checkbutton(
        -text => $text, -variable => $varref, -onvalue => 1, -offvalue => 0,
        -background => $BAR_BG, -activebackground => $BAR_BG,
        -foreground => '#1a1f29', -activeforeground => '#000000',
        -selectcolor => '#4f8cff',
        -font => 'TkDefaultFont 8', -anchor => 'w',
        ( $cmd ? ( -command => $cmd ) : () ),
    );
    $cb->configure(-state => 'disabled') if $disabled;
    $cb->pack(-side => 'left', -anchor => 'w', -padx => 2);
    return $cb;
};

# =============================================================================
# Columna SMC STRUCTURES 2 (motor autonomo, replica fiel del Pine, sin ZigZag)
# =============================================================================
my %SMC2 = (
    show_bos_swing => 0, show_bos_internal => 0,
    show_choch_swing => 0, show_choch_internal => 0,
    show_fvg => 0, show_hhll => 0,
    show_eq => 0, show_ob_swing => 0, show_ob_internal => 0,
    show_trend_bars => 0, show_hl => 0, show_pd_zones => 0, show_mtf => 0,
);
my $smc2_master = 0;
my $refresh_smc2 = sub {
    $smc2_overlay->set_flag($_, $SMC2{$_}) for keys %SMC2;
    my $any = 0; $any ||= $SMC2{$_} for keys %SMC2;
    $overlay_mgr->set_visible('smc2', $any);
    $engine->request_render;
};
my $sync_smc2_master = sub {
    my $all = 1; $all &&= $SMC2{$_} for keys %SMC2;
    $smc2_master = $all;
};
my $leaf_smc2 = sub { $refresh_smc2->(); $sync_smc2_master->(); };

my $col_smc2 = $make_col->('SMC Structures 2', '#c9a24b');
$make_chk->($col_smc2, 'Activar SMC2', \$smc2_master, sub {
    $SMC2{$_} = $smc2_master for keys %SMC2;
    $refresh_smc2->();
});
$make_chk->($col_smc2, 'BOS (swing)',    \$SMC2{show_bos_swing},    $leaf_smc2);
$make_chk->($col_smc2, 'BOS (interno)',  \$SMC2{show_bos_internal}, $leaf_smc2);
$make_chk->($col_smc2, 'CHoCH (swing)',  \$SMC2{show_choch_swing},    $leaf_smc2);
$make_chk->($col_smc2, 'CHoCH (interno)',\$SMC2{show_choch_internal}, $leaf_smc2);
$make_chk->($col_smc2, 'FVG',            \$SMC2{show_fvg},         $leaf_smc2);
$make_chk->($col_smc2, 'HH/HL/LH/LL',    \$SMC2{show_hhll},        $leaf_smc2);
$make_chk->($col_smc2, 'EQH/EQL',        \$SMC2{show_eq},          $leaf_smc2);
$make_chk->($col_smc2, 'OB Swing',       \$SMC2{show_ob_swing},    $leaf_smc2);
$make_chk->($col_smc2, 'OB Internal',    \$SMC2{show_ob_internal}, $leaf_smc2);
$make_chk->($col_smc2, 'Trend Bars',     \$SMC2{show_trend_bars},  $leaf_smc2);
$make_chk->($col_smc2, 'Strong/Weak H-L',\$SMC2{show_hl},          $leaf_smc2);
$make_chk->($col_smc2, 'Premium/Discount',\$SMC2{show_pd_zones},   $leaf_smc2);
$make_chk->($col_smc2, 'MTF Levels',     \$SMC2{show_mtf},         $leaf_smc2);

$tools_bar->Frame(-background => '#2a3445', -width => 1, -height => 16)
    ->pack(-side => 'left', -pady => 4, -padx => 4);

# =============================================================================
# Columna ANCHORED VOLUME PROFILE (auto/manual)
# =============================================================================
my $avp_master = 0;
my $refresh_avp = sub {
    $avp_overlay->set_flag('show', $avp_master);
    $overlay_mgr->set_visible('avp', $avp_master);
    $engine->request_render;
};

my $col_avp = $make_col->('Anchored Volume Profile', '#ffd700');
$make_chk->($col_avp, 'Activar AVP', \$avp_master, $refresh_avp);

my $btn_avp_auto;
my $btn_avp_manual;
$btn_avp_auto = $col_avp->Button(%bs,
    -text    => 'Auto',
    -font    => 'TkDefaultFont 8 bold',
    -foreground => '#26a69a',
    -command => sub {
        $avp_ind->set_mode('auto');
        $btn_avp_auto->configure(-foreground => '#26a69a');
        $btn_avp_manual->configure(-foreground => '#1a1f29');
        $engine->set_avp_select_mode(0);
        $engine->request_render;
    },
)->pack(-side => 'left', -padx => 2);

$btn_avp_manual = $col_avp->Button(%bs,
    -text    => 'Manual: clic vela',
    -font    => 'TkDefaultFont 8 bold',
    -foreground => '#1a1f29',
    -command => sub {
        $avp_ind->set_mode('manual');
        $btn_avp_auto->configure(-foreground => '#1a1f29');
        $btn_avp_manual->configure(-foreground => '#ef5350');
        $engine->set_avp_select_mode(1);   # queda armado para el proximo clic
    },
)->pack(-side => 'left', -padx => 2);

$engine->set_avp_click_cb(sub {
    my ($idx) = @_;
    $avp_ind->set_manual_anchor($idx);
    $btn_avp_manual->configure(-foreground => '#1a1f29');
    $engine->request_render;
});

# =============================================================================
# Columna ZIGZAG MTF (direccion INTERNA) — remuestreo OHLC + zigzag por periodo
# =============================================================================
my %ZZMTF = ( show => 0 );
my $refresh_zzmtf = sub {
    $zzmtf_overlay->set_flag('show', $ZZMTF{show});
    $overlay_mgr->set_visible('zzmtf', $ZZMTF{show});
    $engine->request_render;
};

my $col_zzmtf = $make_col->('ZigZag MTF (Interna)', '#26a69a');
$make_chk->($col_zzmtf, 'Mostrar ZigZag Interno', \$ZZMTF{show}, $refresh_zzmtf);

$tools_bar->Frame(-background => '#2a3445', -width => 1, -height => 16)
    ->pack(-side => 'left', -pady => 4, -padx => 4);

# =============================================================================
# Columna ZIGZAG VOLUME PROFILE (direccion EXTERNA) — ahora usa ZZVP2
# =============================================================================
my $col_zzvp = $make_col->('ZigZag Volume Profile (Externa)', '#7e57c2');
my $zzvp2_on = 0;
$make_chk->($col_zzvp, 'Activar Zigzag Volumen', \$zzvp2_on, sub {
    $overlay_mgr->set_visible('zzvp2', $zzvp2_on);
    $engine->request_render;
});

$tools_bar->Frame(-background => '#2a3445', -width => 1, -height => 16)
    ->pack(-side => 'left', -pady => 4, -padx => 4);

$tools_bar->Frame(-background => '#2a3445', -width => 1, -height => 16)
    ->pack(-side => 'left', -pady => 4, -padx => 4);

# =============================================================================
# Columna LIQUIDITY (Swing / BSL / SSL / EQH / EQL / Sweeps / Grabs / Runs)
# =============================================================================
my %LIQ = (
    show_swing => 0, show_trendline => 0,
    show_bsl => 0, show_ssl => 0, show_eqh => 0,
    show_eql => 0, show_sweeps => 0, show_grabs => 0, show_runs => 0,
);
my $liq_master = 0;
my $refresh_liq = sub {
    $liq_overlay->set_flag($_, $LIQ{$_}) for keys %LIQ;
    my $any = 0; $any ||= $LIQ{$_} for keys %LIQ;
    $overlay_mgr->set_visible('liquidity', $any ? 1 : 0);
    $engine->request_render;
};
my $sync_liq_master = sub {
    my $all = 1; $all &&= $LIQ{$_} for keys %LIQ;
    $liq_master = $all ? 1 : 0;
};
my $leaf_liq = sub { $refresh_liq->(); $sync_liq_master->(); };

my $col_liq = $make_col->('Liquidity', '#ef5350');
$make_chk->($col_liq, 'Activar Liquidity', \$liq_master, sub {
    $LIQ{$_} = $liq_master for keys %LIQ;
    $refresh_liq->();
});
$make_chk->($col_liq, 'BSL - Buy Side',  \$LIQ{show_bsl},  $leaf_liq);
$make_chk->($col_liq, 'SSL - Sell Side', \$LIQ{show_ssl},  $leaf_liq);
$make_chk->($col_liq, 'EQH',     \$LIQ{show_eqh},    $leaf_liq);
$make_chk->($col_liq, 'EQL',     \$LIQ{show_eql},    $leaf_liq);
$make_chk->($col_liq, 'Sweeps',  \$LIQ{show_sweeps}, $leaf_liq);
$make_chk->($col_liq, 'Grabs',   \$LIQ{show_grabs},  $leaf_liq);
$make_chk->($col_liq, 'Runs',    \$LIQ{show_runs},   $leaf_liq);

# =============================================================================
# PRIMER RENDER
# =============================================================================
$engine->reset_view;
$mw->after(80, sub { $engine->render });
MainLoop;