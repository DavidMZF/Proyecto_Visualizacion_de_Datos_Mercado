#!/usr/bin/perl
use strict;
use warnings;
use lib '.';

use Market::MarketData;
use Market::IndicatorManager;
use Market::Indicators::ATR;
use Market::ChartEngine;

use Tk;
use Tk::Frame;
use Time::Moment;

my $CSV_FILE   = 'data/2026_03.csv';
my $ATR_PERIOD = 14;
my $WINDOW_W   = 1200;
my $WINDOW_H   = 700;
my $PRICE_H    = 520;
my $ATR_H      = 120;
my $MARGIN_R   = 70;

# ═══════════════════════════════════════════════════════════
# 1. CARGAR DATOS
# ═══════════════════════════════════════════════════════════

my $market = Market::MarketData->new();

open(my $fh, '<', $CSV_FILE)
    or die "No se puede abrir '$CSV_FILE': $!\n";

my $header = <$fh>;

while (my $line = <$fh>) {
    chomp $line;
    next unless $line =~ /\S/;

    my ($time_str, $open, $high, $low, $close, $volume) = split /,/, $line;
    next unless defined $close;

    $time_str =~ s/^\s+|\s+$//g;

    my $epoch;
    eval {
        my $tm = Time::Moment->from_string($time_str);
        $epoch = $tm->epoch();
    };
    if ($@) {
        warn "Timestamp inválido: '$time_str'\n";
        next;
    }

    for my $val ($open, $high, $low, $close) {
        $val //= 0;
        $val =~ s/^\s+|\s+$//g;
    }
    $volume //= 0;
    $volume =~ s/^\s+|\s+$//g;

    next unless $open && $high && $low && $close;

    $market->add_candle({
        time   => $epoch,
        open   => $open   + 0,
        high   => $high   + 0,
        low    => $low    + 0,
        close  => $close  + 0,
        volume => $volume + 0,
    });
}
close($fh);

die "CSV vacío o sin datos válidos.\n" unless $market->size() > 0;
print "Cargadas " . $market->size() . " velas desde '$CSV_FILE'\n";

# ═══════════════════════════════════════════════════════════
# 2. TEMPORALIDADES E INDICADORES
# ═══════════════════════════════════════════════════════════

$market->build_timeframes();
print "Temporalidades construidas: 1m, 5m, 15m\n";

my $indicators = Market::IndicatorManager->new();
$indicators->register('ATR', Market::Indicators::ATR->new($ATR_PERIOD));
$indicators->update_last($market);
print "ATR($ATR_PERIOD) calculado.\n";

# ═══════════════════════════════════════════════════════════
# 3. VENTANA TK
# ═══════════════════════════════════════════════════════════

my $mw = MainWindow->new();
$mw->title('Chart Engine');
$mw->geometry("${WINDOW_W}x${WINDOW_H}");
$mw->configure(-background => '#131722');
$mw->resizable(1, 1);

# Toolbar
my $toolbar = $mw->Frame(
    -background => '#1e222d',
    -relief     => 'flat',
)->pack(-side => 'top', -fill => 'x', -ipady => 4);

$toolbar->Label(
    -text       => 'Temporalidad:',
    -foreground => '#888888',
    -background => '#1e222d',
    -font       => ['sans-serif', 9],
)->pack(-side => 'left', -padx => 10);

# Área de canvas
my $chart_frame = $mw->Frame(
    -background => '#131722',
)->pack(-side => 'top', -fill => 'both', -expand => 1);

# ATR y separador se anclan al fondo primero.
# canvas_price toma todo el espacio vertical restante con expand.
# Si se hiciera al revés (price primero con expand), canvas_price consumiría
# todo el frame y los widgets siguientes quedarían fuera del área visible.
my $canvas_atr = $chart_frame->Canvas(
    -width              => $WINDOW_W,
    -height             => $ATR_H,
    -background         => '#131722',
    -relief             => 'flat',
    -bd                 => 0,
    -highlightthickness => 0,
)->pack(-side => 'bottom', -fill => 'x');

$chart_frame->Frame(
    -background => '#2a2e39',
    -height     => 1,
)->pack(-side => 'bottom', -fill => 'x');

my $canvas_price = $chart_frame->Canvas(
    -width              => $WINDOW_W,
    -height             => $PRICE_H,
    -background         => '#131722',
    -relief             => 'flat',
    -bd                 => 0,
    -highlightthickness => 0,
)->pack(-side => 'top', -fill => 'both', -expand => 1);

# Barra de estado
my $statusbar = $mw->Frame(
    -background => '#1e222d',
)->pack(-side => 'bottom', -fill => 'x', -ipady => 2);

my $status_label = $statusbar->Label(
    -text       => 'Listo  |  Rueda: zoom  |  Drag izq: scroll  |  Drag der: mover precio  |  R: reset',
    -foreground => '#888888',
    -background => '#1e222d',
    -font       => ['monospace', 8],
    -anchor     => 'w',
)->pack(-side => 'left', -padx => 10);

# ═══════════════════════════════════════════════════════════
# 4. CHART ENGINE
# ═══════════════════════════════════════════════════════════

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

# ═══════════════════════════════════════════════════════════
# 5. BOTONES DE TIMEFRAME
# ═══════════════════════════════════════════════════════════

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
            $status_label->configure(-text => "Temporalidad: ${label}");
        },
    )->pack(-side => 'left', -padx => 2);
}

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

# ═══════════════════════════════════════════════════════════
# 6. RESIZE — disparar cuando cambia ancho o alto
# ═══════════════════════════════════════════════════════════

my $last_configure_w = 0;
my $last_configure_h = 0;

$mw->bind('<Configure>', sub {
    my $new_w = $mw->width();
    my $new_h = $mw->height();
    return if $new_w == $last_configure_w && $new_h == $last_configure_h;
    $last_configure_w = $new_w;
    $last_configure_h = $new_h;

    $engine->{canvas_w}                  = $new_w;
    $engine->{scale_price}{canvas_width} = $new_w;
    $engine->{scale_atr}{canvas_width}   = $new_w;

    # Propagar la nueva altura del panel de precio al engine
    my $new_price_h = $canvas_price->height();
    if ($new_price_h > 10) {
        $engine->{canvas_price_h}             = $new_price_h;
        $engine->{scale_price}{canvas_height} = $new_price_h;
    }

    $engine->request_render();
});

# ═══════════════════════════════════════════════════════════
# 7. ARRANQUE
# ═══════════════════════════════════════════════════════════

print "Iniciando ventana gráfica...\n";
$engine->request_render();
MainLoop();