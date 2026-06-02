package Market::ChartEngine;
use strict;
use warnings;
use Tk qw(Ev);

use lib '.';

use Market::Panels::Scales;
use Market::Panels::PricePanel;
use Market::Panels::ATRPanel;

sub new {
    my ($class, %args) = @_;

    my $self = {
        market_data  => $args{market_data},
        indicators   => $args{indicators},
        canvas_price => $args{canvas_price},
        canvas_atr   => $args{canvas_atr},

        canvas_w       => $args{canvas_w}       // 800,
        canvas_price_h => $args{canvas_price_h} // 400,
        canvas_atr_h   => $args{canvas_atr_h}   // 120,
        margin_right   => $args{margin_right}   // 70,
        margin_bottom  => 20,

        visible_bars  => $args{visible_bars} // 100,
        offset        => 0,
        
        view_mode     => 'auto',                # 'auto' o 'manual'
        y_min_manual  => undef,
        y_max_manual  => undef,
        y_drag_start  => undef,

        _render_pending => 0,

        price_panel => undef,
        atr_panel   => undef,
        scale_price => undef,
        scale_atr   => undef,

        tf_buttons => $args{tf_buttons} // {},
    };

    bless $self, $class;
    $self->_init_panels();
    $self->bind_events();
    $self->reset_view();
    return $self;
}

sub _init_panels {
    my ($self) = @_;

    $self->{scale_price} = Market::Panels::Scales->new(
        canvas_width  => $self->{canvas_w},
        canvas_height => $self->{canvas_price_h},
        margin_right  => $self->{margin_right},
        margin_bottom => $self->{margin_bottom},
        visible_bars  => $self->{visible_bars},
        offset        => 0,
        y_min         => 0,
        y_max         => 1,
    );

    $self->{scale_atr} = Market::Panels::Scales->new(
        canvas_width  => $self->{canvas_w},
        canvas_height => $self->{canvas_atr_h},
        margin_right  => $self->{margin_right},
        margin_bottom => $self->{margin_bottom},
        visible_bars  => $self->{visible_bars},
        offset        => 0,
        y_min         => 0,
        y_max         => 1,
    );

    $self->{price_panel} = Market::Panels::PricePanel->new(
        canvas      => $self->{canvas_price},
        scale       => $self->{scale_price},
        market_data => $self->{market_data},
        indicators  => $self->{indicators},
    );

    $self->{atr_panel} = Market::Panels::ATRPanel->new(
        canvas => $self->{canvas_atr},
        scale  => $self->{scale_atr},
    );
}

sub compute_window {
    my ($self) = @_;
    my $size = $self->{market_data}->size();
    return (0, 0) if $size == 0;

    my $max_offset = $size - 1;
    $self->{offset} = 0           if $self->{offset} < 0;
    $self->{offset} = $max_offset if $self->{offset} > $max_offset;

    my $end   = ($size - 1) - $self->{offset};
    my $start = $end - $self->{visible_bars} + 1;

    if ($start < 0) {
        $start = 0;
    }

    $end = $size - 1 if $end >= $size;
    return ($start, $end);
}

sub request_render {
    my ($self) = @_;
    return if $self->{_render_pending};
    $self->{_render_pending} = 1;
    $self->{canvas_price}->after(0, sub {
        $self->{_render_pending} = 0;
        $self->render();
    });
}

sub render {
    my ($self) = @_;

    my $size = $self->{market_data}->size();
    return if $size == 0;

    # ── NUEVO: REDIMENSIONAMIENTO RESPONSIVO Y DINÁMICO ──
    # Leemos el tamaño físico real que el sistema operativo le asignó al Canvas estirado
    my $current_w_price = $self->{canvas_price}->width;
    my $current_h_price = $self->{canvas_price}->height;
    my $current_w_atr   = $self->{canvas_atr}->width;
    my $current_h_atr   = $self->{canvas_atr}->height;

    # Evitamos procesar si la ventana aún no se despliega en pantalla (valores iniciales <= 1)
    if ($current_w_price > 10 && $current_h_price > 10) {
        $self->{scale_price}{canvas_width}  = $current_w_price;
        $self->{scale_price}{canvas_height} = $current_h_price;
    }
    if ($current_w_atr > 10 && $current_h_atr > 10) {
        $self->{scale_atr}{canvas_width}  = $current_w_atr;
        $self->{scale_atr}{canvas_height} = $current_h_atr;
    }

    # Anclaje defensivo de pantallas
    $self->{canvas_price}->xviewMoveto(0);
    $self->{canvas_price}->yviewMoveto(0);
    $self->{canvas_atr}->xviewMoveto(0);
    $self->{canvas_atr}->yviewMoveto(0);

    my ($start, $end) = $self->compute_window();

    my $price_data = $self->{market_data}->get_slice($start, $end);
    my $atr_values = $self->{indicators}->slice_array('ATR', $start, $end);

    my $actual_bars = $end - $start + 1;

    $self->{scale_price}{visible_bars} = $actual_bars;
    $self->{scale_price}{offset}       = $start;

    $self->{scale_atr}{visible_bars}   = $actual_bars;
    $self->{scale_atr}{offset}         = $start;

    my ($y_min, $y_max);

    if ($self->{view_mode} eq 'manual') {
        unless (defined $self->{y_min_manual} && defined $self->{y_max_manual}) {
            ($self->{y_min_manual}, $self->{y_max_manual}) = $self->{price_panel}->get_y_range($price_data);
        }
        $y_min = $self->{y_min_manual};
        $y_max = $self->{y_max_manual};
    } else {
        ($y_min, $y_max) = $self->{price_panel}->get_y_range($price_data);
        $self->{y_min_manual} = undef;
        $self->{y_max_manual} = undef;
    }

    $self->{scale_price}{y_min} = $y_min;
    $self->{scale_price}{y_max} = $y_max;

    my ($atr_min, $atr_max) = $self->{atr_panel}->get_y_range($atr_values);
    $self->{scale_atr}{y_min} = $atr_min;
    $self->{scale_atr}{y_max} = $atr_max;

    $self->{price_panel}->render($self->{canvas_price}, $price_data, $self->{scale_price});
    $self->{atr_panel}->render($self->{canvas_atr}, $atr_values, $self->{scale_atr});

    my $timestamps = $self->compute_intraday_labels();
    $self->{price_panel}->draw_time_axis($self->{canvas_price}, $timestamps);

    # Renderizado estricto del indicador de estado en pantalla
    $self->{canvas_price}->delete('mode_status_indicator');
    
    my $text_to_show = $self->{view_mode} eq 'auto' 
                       ? "ESC: ESCALA AUTOMÁTICA" 
                       : "ESC: ESCALA MANUAL (Arrastre 2D habilitado)";
    my $text_color   = $self->{view_mode} eq 'auto' ? '#00ff00' : '#ffa500';

    $self->{canvas_price}->createText(
        15, 15,
        -text   => $text_to_show,
        -fill   => $text_color,
        -anchor => 'nw',
        -font   => 'Helvetica 10 bold',
        -tags   => 'mode_status_indicator'
    );
}

sub _bind_all_canvas {
    my ($self, $event, $callback) = @_;
    $self->{canvas_price}->CanvasBind($event => $callback);
    $self->{canvas_atr}->CanvasBind($event => $callback);
}

sub bind_events {
    my ($self) = @_;

    my $drag_start_x       = undef;
    my $drag_start_y       = undef;
    my $drag_start_offset  = undef;
    my $drag_base_y_min    = undef;
    my $drag_base_y_max    = undef;

    my $main_window = $self->{canvas_price}->toplevel;

    $self->_bind_all_canvas('<Enter>', sub {
        my $canvas = shift;
        $canvas->focusForce();
    });

    # ── NUEVO: DETECTAR CAMBIOS DE TAMAÑO ESTRUCTURALES (RESPONSIVO) ──
    # Cuando la ventana se maximiza o arrastra, fuerza un recalculo inmediato
    $self->{canvas_price}->bind('<Configure>', sub { $self->request_render(); });
    $self->{canvas_atr}->bind('<Configure>', sub { $self->request_render(); });

    # Drag asistido
    $self->_bind_all_canvas('<ButtonPress-1>', [sub {
        my ($canvas, $x, $y) = @_;
        $canvas->focusForce();
        $drag_start_x      = $x;
        $drag_start_y      = $y;
        $drag_start_offset = $self->{offset};
        $drag_base_y_min   = $self->{scale_price}{y_min};
        $drag_base_y_max   = $self->{scale_price}{y_max};
    }, Ev('x'), Ev('y')]);

    $self->_bind_all_canvas('<B1-Motion>', [sub {
        my ($canvas, $x, $y) = @_;
        return unless defined $drag_start_x;

        my $bar_w = $self->{scale_price}->_bar_width();
        if ($bar_w >= 0.5) {
            my $delta_bars = int(($x - $drag_start_x) / $bar_w);
            $self->{offset} = $drag_start_offset - $delta_bars;

            my $size = $self->{market_data}->size();
            $self->{offset} = 0         if $self->{offset} < 0;
            $self->{offset} = $size - 1 if $self->{offset} > $size - 1;
        }

        if ($self->{view_mode} eq 'manual' && defined $drag_base_y_min) {
            my $dy    = $y - $drag_start_y;
            my $range = $drag_base_y_max - $drag_base_y_min;
            my $ph    = $self->{scale_price}->plot_height();
            
            if ($ph > 0) {
                my $price_shift = ($dy / $ph) * $range;
                $self->{y_min_manual} = $drag_base_y_min - $price_shift;
                $self->{y_max_manual} = $drag_base_y_max - $price_shift;
            }
        }

        $self->request_render();
    }, Ev('x'), Ev('y')]);

    $self->_bind_all_canvas('<ButtonRelease-1>', sub {
        $drag_start_x = undef;
        $drag_start_y = undef;
    });

    # Rueda del ratón
    $self->_bind_all_canvas('<MouseWheel>', [sub {
        my ($canvas, $delta) = @_;
        $self->_horizontal_zoom($delta > 0 ? -1 : 1);
        $canvas->break;
    }, Ev('D')]);

    $self->_bind_all_canvas('<Button-4>', sub { my $c = shift; $self->_horizontal_zoom(-1); $c->break; });
    $self->_bind_all_canvas('<Button-5>', sub { my $c = shift; $self->_horizontal_zoom(1);  $c->break; });

    # Click derecho
    $self->{canvas_price}->CanvasBind('<ButtonPress-3>', [sub {
        my ($canvas, $x, $y) = @_;
        $canvas->focusForce();
        $self->{view_mode}    = 'manual';
        $self->{y_drag_start} = $y;
        $self->request_render();
    }, Ev('x'), Ev('y')]);

    $self->{canvas_price}->CanvasBind('<B3-Motion>', [sub {
        my ($canvas, $x, $y) = @_;
        return unless defined $self->{y_drag_start};
        my $dy = $y - $self->{y_drag_start};
        $self->_vertical_drag($dy);
        $self->{y_drag_start} = $y;
    }, Ev('x'), Ev('y')]);

    $self->{canvas_price}->CanvasBind('<Double-ButtonPress-3>', sub {
        $self->set_view_mode('auto');
    });

    $self->{canvas_price}->CanvasBind('<Control-Button-4>', sub { my $c = shift; $self->{view_mode} = 'manual'; $self->_vertical_zoom(0.90); $c->break; });
    $self->{canvas_price}->CanvasBind('<Control-Button-5>', sub { my $c = shift; $self->{view_mode} = 'manual'; $self->_vertical_zoom(1.10); $c->break; });

    $self->_bind_all_canvas('<Motion>', [sub {
        my ($canvas, $x, $y) = @_;
        $self->_draw_crosshair_all($x, $y);
    }, Ev('x'), Ev('y')]);

    # Bindings Globales a nivel de Ventana Principal
    $main_window->bind('<Key-1>', sub { $self->set_timeframe('1');  });
    $main_window->bind('<Key-5>', sub { $self->set_timeframe('5');  });
    $main_window->bind('<Key-6>', sub { $self->set_timeframe('15'); });
    
    $main_window->bind('<Key-a>', sub { $self->set_view_mode('auto'); });
    $main_window->bind('<Key-A>', sub { $self->set_view_mode('auto'); });
    
    $main_window->bind('<Key-m>', sub { $self->set_view_mode('manual'); });
    $main_window->bind('<Key-M>', sub { $self->set_view_mode('manual'); });
    
    $main_window->bind('<Key-r>', sub { $self->reset_view(); });
    $main_window->bind('<Key-R>', sub { $self->reset_view(); });

    $self->{canvas_price}->focusForce();
}

sub set_view_mode {
    my ($self, $mode) = @_;
    $self->{view_mode} = $mode;
    if ($mode eq 'auto') {
        $self->{y_min_manual} = undef;
        $self->{y_max_manual} = undef;
    }
    $self->request_render();
}

sub _horizontal_zoom {
    my ($self, $delta) = @_;
    my $factor   = $delta < 0 ? 0.90 : 1.10;
    my $new_bars = int($self->{visible_bars} * $factor);
    my $size     = $self->{market_data}->size();

    $new_bars = 10    if $new_bars < 10;
    $new_bars = $size if $new_bars > $size;

    return if $new_bars == $self->{visible_bars};
    $self->{visible_bars} = $new_bars;
    $self->request_render();
}

sub _vertical_drag {
    my ($self, $dy) = @_;
    my $scale = $self->{scale_price};

    unless (defined $self->{y_min_manual}) {
        $self->{y_min_manual} = $scale->{y_min};
        $self->{y_max_manual} = $scale->{y_max};
    }

    my $range = $self->{y_max_manual} - $self->{y_min_manual};
    my $ph    = $scale->plot_height();
    return if $ph == 0;

    my $price_shift = ($dy / $ph) * $range;
    $self->{y_min_manual} -= $price_shift;
    $self->{y_max_manual} -= $price_shift;
    $self->request_render();
}

sub _vertical_zoom {
    my ($self, $factor) = @_;
    my $scale = $self->{scale_price};

    unless (defined $self->{y_min_manual}) {
        $self->{y_min_manual} = $scale->{y_min};
        $self->{y_max_manual} = $scale->{y_max};
    }

    my $mid  = ($self->{y_min_manual} + $self->{y_max_manual}) / 2;
    my $half = ($self->{y_max_manual} - $self->{y_min_manual}) / 2;

    $half *= $factor;
    $self->{y_min_manual} = $mid - $half;
    $self->{y_max_manual} = $mid + $half;
    $self->request_render();
}

sub _draw_crosshair_all {
    my ($self, $x, $y) = @_;
    $self->{price_panel}->draw_crosshair($x, $y);
    my $atr_y = $self->{canvas_atr_h} / 2;
    $self->{atr_panel}->draw_crosshair($x, $atr_y);
}

sub set_timeframe {
    my ($self, $tf) = @_;
    $self->{market_data}->set_timeframe($tf);
    $self->{indicators}->reset_all();
    $self->{indicators}->update_last($self->{market_data});
    $self->reset_view();
}

sub reset_view {
    my ($self) = @_;
    $self->{offset}       = 0;
    $self->{view_mode}    = 'auto';
    $self->{y_min_manual} = undef;
    $self->{y_max_manual} = undef;
    $self->{visible_bars} = 100;
    $self->request_render();
}

sub compute_intraday_labels {
    my ($self) = @_;
    my ($start, $end) = $self->compute_window();
    my $visible  = $end - $start + 1;
    my $n_labels = 6;
    my $step     = int($visible / $n_labels) || 1;
    my @labels;

    for (my $i = $start; $i <= $end; $i += $step) {
        my $ts = $self->{market_data}->get_timestamp($i);
        next unless defined $ts;
        my @t     = localtime($ts);
        my $label = sprintf("%02d:%02d", $t[2], $t[1]);
        push @labels, [$i, $label];
    }
    return \@labels;
}

sub get_all_timestamps {
    my ($self) = @_;
    my ($start, $end) = $self->compute_window();
    my @result;
    for my $i ($start .. $end) {
        my $ts = $self->{market_data}->get_timestamp($i);
        push @result, [$i, $ts] if defined $ts;
    }
    return \@result;
}

1;