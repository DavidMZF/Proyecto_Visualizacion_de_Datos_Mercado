#!/usr/bin/perl
use strict;
use warnings;
use lib '.';

# ─── Módulos del sistema ──────────────────────────────────────────────────────
use Market::MarketData;
use Market::IndicatorManager;
use Market::Indicators::ATR;
use Market::ChartEngine;

# ─── Módulos Tk ───────────────────────────────────────────────────────────────
use Tk;
use Tk::Frame;

use Time::Moment;

# ─── Configuración general ────────────────────────────────────────────────────
my $CSV_FILE    = 'data/2026_03.csv';
my $ATR_PERIOD  = 14;
my $WINDOW_W    = 1200;
my $WINDOW_H    = 700;
my $PRICE_H     = 520;
my $ATR_H       = 120;
my $MARGIN_R    = 70;

# ═════════════════════════════════════════════════════════════════════════════
# 1. CARGAR DATOS DESDE CSV
# ═════════════════════════════════════════════════════════════════════════════

my $market = Market::MarketData->new();

open(my $fh, '<', $CSV_FILE)
    or die "No se puede abrir '$CSV_FILE': $!\n";

my $header = <$fh>;    # saltar encabezado

while (my $line = <$fh>) {
    chomp $line;
    next unless $line =~ /\S/;

    my ($time_str, $open, $high, $low, $close, $volume) = split /,/, $line;

    next unless defined $close;

    # Limpiar espacios
    $time_str =~ s/^\s+|\s+$//g;

    # Convertir ISO 8601 → epoch Unix usando Time::Moment
    my $epoch;
    eval {
        my $tm = Time::Moment->from_string($time_str);
        $epoch = $tm->epoch();
    };
    if ($@) {
        warn "Timestamp inválido en línea: '$time_str', saltando.\n";
        next;
    }

    # Limpiar y validar valores numéricos
    for my $val ($open, $high, $low, $close) {
        $val //= 0;
        $val =~ s/^\s+|\s+$//g;
    }
    $volume //= 0;
    $volume =~ s/^\s+|\s+$//g;

    next unless $open && $high && $low && $close;

    $market->add_candle({
        time   => $epoch,
        open   => $open  + 0,
        high   => $high  + 0,
        low    => $low   + 0,
        close  => $close + 0,
        volume => $volume + 0,
    });
}
close($fh);

die "El archivo CSV está vacío o no tiene datos válidos.\n"
    unless $market->size() > 0;

print "Cargadas " . $market->size() . " velas desde '$CSV_FILE'\n";

# ═════════════════════════════════════════════════════════════════════════════
# 2. CONSTRUIR TEMPORALIDADES
# ═════════════════════════════════════════════════════════════════════════════

$market->build_timeframes();

print "Temporalidades construidas: 1m, 5m, 15m\n";

# ═════════════════════════════════════════════════════════════════════════════
# 3. REGISTRAR Y CALCULAR INDICADORES
# ═════════════════════════════════════════════════════════════════════════════

my $indicators = Market::IndicatorManager->new();
$indicators->register('ATR', Market::Indicators::ATR->new($ATR_PERIOD));
$indicators->update_last($market);

print "ATR($ATR_PERIOD) calculado.\n";

# ═════════════════════════════════════════════════════════════════════════════
# 4. CONSTRUIR VENTANA TK
# ═════════════════════════════════════════════════════════════════════════════

my $mw = MainWindow->new();
$mw->title('Chart Engine — TradingView Clone');
$mw->geometry("${WINDOW_W}x${WINDOW_H}");
$mw->configure(-background => '#131722');
$mw->resizable(1, 1);

# ─── Barra superior: botones de timeframe ────────────────────────────────────
my $toolbar = $mw->Frame(
    -background => '#1e222d',
    -relief     => 'flat',
)->pack(-side => 'top', -fill => 'x', -ipady => 4);

my $lbl_tf = $toolbar->Label(
    -text       => 'Temporalidad:',
    -foreground => '#888888',
    -background => '#1e222d',
    -font       => ['sans-serif', 9],
)->pack(-side => 'left', -padx => 10);

# ─── Área principal de canvas ─────────────────────────────────────────────────
my $chart_frame = $mw->Frame(
    -background => '#131722',
)->pack(-side => 'top', -fill => 'both', -expand => 1);

# Canvas del panel de precios (parte superior)
my $canvas_price = $chart_frame->Canvas(
    -width      => $WINDOW_W,
    -height     => $PRICE_H,
    -background => '#131722',
    -relief     => 'flat',
    -bd         => 0,
    -highlightthickness => 0,
)->pack(-side => 'top', -fill => 'both', -expand => 1);

# Separador visual entre paneles
$chart_frame->Frame(
    -background => '#2a2e39',
    -height     => 1,
)->pack(-side => 'top', -fill => 'x');

# Canvas del panel ATR (parte inferior)
my $canvas_atr = $chart_frame->Canvas(
    -width      => $WINDOW_W,
    -height     => $ATR_H,
    -background => '#131722',
    -relief     => 'flat',
    -bd         => 0,
    -highlightthickness => 0,
)->pack(-side => 'top', -fill => 'x');

# ─── Barra de estado inferior ─────────────────────────────────────────────────
my $statusbar = $mw->Frame(
    -background => '#1e222d',
)->pack(-side => 'bottom', -fill => 'x', -ipady => 2);

my $status_label = $statusbar->Label(
    -text       => 'Listo',
    -foreground => '#888888',
    -background => '#1e222d',
    -font       => ['monospace', 8],
    -anchor     => 'w',
)->pack(-side => 'left', -padx => 10);

# ═════════════════════════════════════════════════════════════════════════════
# 5. INSTANCIAR CHART ENGINE
# ═════════════════════════════════════════════════════════════════════════════

my $engine = Market::ChartEngine->new(
    market_data    => $market,
    indicators     => $indicators,
    canvas_price   => $canvas_price,
    canvas_atr     => $canvas_atr,
    canvas_w       => $WINDOW_W,
    canvas_price_h => $PRICE_H,
    canvas_atr_h   => $ATR_H,
    margin_right   => $MARGIN_R,
    visible_bars   => 100,
);

# ═════════════════════════════════════════════════════════════════════════════
# 6. BOTONES DE TIMEFRAME (necesitan referencia al engine)
# ═════════════════════════════════════════════════════════════════════════════

for my $tf (['1m', '1'], ['5m', '5'], ['15m', '15']) {
    my ($label, $value) = @$tf;
    $toolbar->Button(
        -text             => $label,
        -foreground       => '#cccccc',
        -background       => '#2a2e39',
        -activeforeground => '#ffffff',
        -activebackground => '#364156',
        -relief           => 'flat',
        -font             => ['sans-serif', 9, 'bold'],
        -padx             => 10,
        -command          => sub {
            $engine->set_timeframe($value);
            $status_label->configure(
                -text => "Temporalidad: ${label}"
            );
        },
    )->pack(-side => 'left', -padx => 2);
}

# Botón de reset de vista
$toolbar->Button(
    -text             => 'Reset',
    -foreground       => '#cccccc',
    -background       => '#2a2e39',
    -activeforeground => '#ffffff',
    -activebackground => '#364156',
    -relief           => 'flat',
    -font             => ['sans-serif', 9],
    -padx             => 10,
    -command          => sub { $engine->reset_view(); },
)->pack(-side => 'left', -padx => 2);

# ═════════════════════════════════════════════════════════════════════════════
# 7. ADAPTAR CANVAS AL REDIMENSIONAR VENTANA
# ═════════════════════════════════════════════════════════════════════════════

$mw->bind('<Configure>', sub {
    my $new_w = $mw->width();
    $engine->{canvas_w}             = $new_w;
    $engine->{scale_price}{canvas_width} = $new_w;
    $engine->{scale_atr}{canvas_width}   = $new_w;
    $engine->request_render();
});

# ═════════════════════════════════════════════════════════════════════════════
# 8. PRIMER RENDER Y LOOP PRINCIPAL
# ═════════════════════════════════════════════════════════════════════════════

print "Iniciando ventana gráfica...\n";
$engine->request_render();

MainLoop();