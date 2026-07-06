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
use Market::Indicators::ZigZagVolumeProfile;
use Market::Overlays::ZigZagMTF;
use Market::Overlays::ZigZagVolumeProfile;

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
for my $cand ("$Bin/data/2026_06_29.csv", "$Bin/2026_06_29.csv", "$Bin/../data/2026_06_29.csv") {
    if (-f $cand) { $csv_path = $cand; last; }
}
die "No se encuentra 2026_06_29.csv\n" unless $csv_path;

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
my $liq_ind = Market::Indicators::Liquidity->new(
    atr        => $atr_ind,
    fractal_n  => 3,     # N velas a cada lado para fractalidad base
    m_atr      => 1.5,   # multiplicador ATR (filtro 1: volatilidad)
    atr_period => 14,
    v_desp     => 10,    # ventana max. de velas para validar desplazamiento
    u_desp     => 2.0,   # multiplicador ATR de recorrido minimo (filtro 2)
);

# ZigZag Multi Time Frame (direccion INTERNA): remuestrea a 30min por
# defecto y corre un zigzag clasico por periodo, independiente de ATR.
my $zzmtf_ind = Market::Indicators::ZigZagMTF->new(
    resolution_minutes => 30,   # 15 | 30 | 60
    period             => 2,    # ZigZag Period (estilo ZZMTF)
);

# 2. PASO CRÍTICO: Inyectamos la referencia del ZigZag al crear SMC_Structures
my $smc_ind = Market::Indicators::SMC_Structures->new(
    liquidity  => $liq_ind, 
    zzmtf      => $zzmtf_ind,   # <-- ESTA LÍNEA CONECTA EL MOTOR ANALÍTICO
    break_mode => 'close' 
);

# ZigZag Volume Profile (direccion EXTERNA): zigzag de mayor grado sobre la
# temporalidad base, con volume profile + POC por pierna.
my $zzvp_ind = Market::Indicators::ZigZagVolumeProfile->new(
    period       => 8,    # mayor que zzmtf: captura estructura de mayor grado
    bins         => 10,
    max_profiles => 15,
);

$ind_manager->register('atr',       $atr_ind);
$ind_manager->register('liquidity', $liq_ind);
$ind_manager->register('zzmtf',     $zzmtf_ind); # <-- Sube a 3er lugar
$ind_manager->register('smc',       $smc_ind);   # <-- Baja a 4to lugar
$ind_manager->register('zzvp',      $zzvp_ind);

print "Calculando indicadores (ATR, Liquidity, SMC, ZigZag MTF/VP)...\n";
$ind_manager->rebuild_all($market);
printf "ATR: %d  |  swings: %d  |  eventos liq: %d  |  eventos BOS/iBOS: %d  |  pivotes ZZMTF: %d  |  piernas ZZVP: %d\n",
    scalar @{ $ind_manager->get('atr') },
    scalar @{ $liq_ind->get_swings },
    scalar @{ $liq_ind->get_events },
    scalar @{ $smc_ind->get_events },
    scalar @{ $zzmtf_ind->get_pivots },
    scalar @{ $zzvp_ind->get_profiles };

# =============================================================================
# OVERLAYS — gestor + overlays reales SMC y Liquidez (Tabla 1, Fase 2)
# Cada overlay solo DIBUJA estructuras ya calculadas por su indicador fuente
# (separacion estricta calculo/render). Nacen OCULTOS: el usuario decide que
# activar de forma independiente desde el menu de herramientas.
# =============================================================================
my $overlay_mgr = Market::OverlayManager->new;
my $smc_overlay   = Market::Overlays::SMC_Structures->new( source => $smc_ind );
my $liq_overlay   = Market::Overlays::Liquidity->new( source => $liq_ind );
my $zzmtf_overlay = Market::Overlays::ZigZagMTF->new( source => $zzmtf_ind );
my $zzvp_overlay  = Market::Overlays::ZigZagVolumeProfile->new( source => $zzvp_ind );
$overlay_mgr->register('smc',       $smc_overlay, visible => 0);
$overlay_mgr->register('liquidity', $liq_overlay, visible => 0);
$overlay_mgr->register('zzmtf',     $zzmtf_overlay, visible => 0);
$overlay_mgr->register('zzvp',      $zzvp_overlay, visible => 0);

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
$replay = Market::Replay->new(
    market     => $market,
    indicators => $ind_manager,
    schedule   => sub { $canvas_price->after(@_); },
    on_change  => sub {
        $engine->follow_replay_pointer;

        my $active  = $replay->is_active;
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

# =============================================================================
# DRAG DEL SEPARADOR ATR
# =============================================================================
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
# Columna SMC STRUCTURES (BOS / iBOS)
# =============================================================================
my %SMC = (
    show_bos  => 0,
    show_ibos => 0,
    show_hhll => 0,
);
my $smc_master = 0;
my $refresh_smc = sub {
    $smc_overlay->set_flag($_, $SMC{$_}) for keys %SMC;
    my $any = ( $SMC{show_bos} || $SMC{show_ibos} || $SMC{show_hhll} ) ? 1 : 0;
    $overlay_mgr->set_visible('smc', $any);
    $engine->request_render;
};
my $sync_smc_master = sub {
    $smc_master = ( $SMC{show_bos} && $SMC{show_ibos} && $SMC{show_hhll} ) ? 1 : 0;
};
my $leaf_smc = sub { $refresh_smc->(); $sync_smc_master->(); };

my $col_smc = $make_col->('SMC Structures', '#4f8cff');
$make_chk->($col_smc, 'Activar SMC', \$smc_master, sub {
    $SMC{$_} = $smc_master for keys %SMC;   # master = encender/apagar TODO SMC
    $refresh_smc->();
});
$make_chk->($col_smc, 'BOS',  \$SMC{show_bos},  $leaf_smc);
$make_chk->($col_smc, 'iBOS', \$SMC{show_ibos}, $leaf_smc);
$make_chk->($col_smc, 'HH/HL/LH/LL', \$SMC{show_hhll}, $leaf_smc);

$tools_bar->Frame(-background => '#2a3445', -width => 1, -height => 16)
    ->pack(-side => 'left', -pady => 4, -padx => 4);

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
# Columna ZIGZAG VOLUME PROFILE (direccion EXTERNA) — zigzag mayor grado + POC
# =============================================================================
my %ZZVP = ( show_zigzag => 0, show_volume_profile => 0, show_poc => 0 );
my $zzvp_master = 0;
my $refresh_zzvp = sub {
    $zzvp_overlay->set_flag($_, $ZZVP{$_}) for keys %ZZVP;
    my $any = ( $ZZVP{show_zigzag} || $ZZVP{show_volume_profile} || $ZZVP{show_poc} ) ? 1 : 0;
    $overlay_mgr->set_visible('zzvp', $any);
    $engine->request_render;
};
my $sync_zzvp_master = sub {
    $zzvp_master =
        ( $ZZVP{show_zigzag} && $ZZVP{show_volume_profile} && $ZZVP{show_poc} ) ? 1 : 0;
};
my $leaf_zzvp = sub { $refresh_zzvp->(); $sync_zzvp_master->(); };

my $col_zzvp = $make_col->('ZigZag Volume Profile (Externa)', '#7e57c2');
$make_chk->($col_zzvp, 'Activar ZZVP', \$zzvp_master, sub {
    $ZZVP{$_} = $zzvp_master for keys %ZZVP;
    $refresh_zzvp->();
});
$make_chk->($col_zzvp, 'ZigZag Externo', \$ZZVP{show_zigzag},         $leaf_zzvp);
$make_chk->($col_zzvp, 'Volume Profile', \$ZZVP{show_volume_profile}, $leaf_zzvp);
$make_chk->($col_zzvp, 'POC',            \$ZZVP{show_poc},            $leaf_zzvp);

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
$make_chk->($col_liq, 'Swing Points',  \$LIQ{show_swing},  $leaf_liq);
$make_chk->($col_liq, 'Trend Line',    \$LIQ{show_trendline}, $leaf_liq);
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