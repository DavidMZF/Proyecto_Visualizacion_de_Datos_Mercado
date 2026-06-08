package Market::ChartEngine;
use strict;
use warnings;
use Tk qw(Ev);

use lib '.';

use Market::Panels::Scales;
use Market::Panels::PricePanel;
use Market::Panels::ATRPanel;

sub new {
    my ( $class, %args ) = @_;

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

        visible_bars => $args{visible_bars} // 100,
        offset       => 0,

        view_mode    => 'auto',
        y_min_manual => undef,
        y_max_manual => undef,
        y_drag_start => undef,

        _cursor_idx    => undef,
        _cursor_x      => undef,
        _cursor_y      => undef,
        _cursor_source => undef,
        _cursor_snap_x => undef,

        _render_pending => 0,

        price_panel => undef,
        atr_panel   => undef,
        scale_price => undef,
        scale_atr   => undef,

        tf_buttons       => $args{tf_buttons} // {},
        _zoom_anchor_idx => undef,
        _zoom_anchor_x   => undef,
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
    return ( 0, 0 ) if $size == 0;

    my $max_offset = $size - 1;
    my $min_offset = 0;

    $self->{offset} = $min_offset if $self->{offset} < $min_offset;
    $self->{offset} = $max_offset if $self->{offset} > $max_offset;

    my $end   = ( $size - 1 ) - $self->{offset};
    my $start = $end - $self->{visible_bars} + 1;

    # Mantener ancho al chocar con borde derecho
    if ( $end > $size - 1 ) {
        my $overflow = $end - ( $size - 1 );
        $end   = $size - 1;
        $start -= $overflow;
    }

    # Mantener ancho al chocar con borde izquierdo
    if ( $start < 0 ) {
        my $underflow = -$start;
        $start = 0;
        $end  += $underflow;
    }

    return ( $start, $end );
}

sub request_render {
    my ($self) = @_;
    return if $self->{_render_pending};
    $self->{_render_pending} = 1;
    $self->{canvas_price}->after(
        0,
        sub {
            $self->{_render_pending} = 0;
            $self->render();
        }
    );
}

sub render {
    my ($self) = @_;

    my $size = $self->{market_data}->size();
    return if $size == 0;

    my $current_w_price = $self->{canvas_price}->width;
    my $current_h_price = $self->{canvas_price}->height;
    my $current_w_atr   = $self->{canvas_atr}->width;
    my $current_h_atr   = $self->{canvas_atr}->height;

    if ( $current_w_price > 10 && $current_h_price > 10 ) {
        $self->{scale_price}{canvas_width}  = $current_w_price;
        $self->{scale_price}{canvas_height} = $current_h_price;
    }

    if ( $current_w_atr > 10 && $current_h_atr > 10 ) {
        $self->{scale_atr}{canvas_width}  = $current_w_atr;
        $self->{scale_atr}{canvas_height} = $current_h_atr;
    }

    $self->{canvas_price}->configure(
        -scrollregion => [ 0, 0, $current_w_price, $current_h_price ]
    );

    $self->{canvas_atr}->configure(
        -scrollregion => [ 0, 0, $current_w_atr, $current_h_atr ]
    );

    $self->{canvas_price}->xviewMoveto(0);
    $self->{canvas_price}->yviewMoveto(0);
    $self->{canvas_atr}->xviewMoveto(0);
    $self->{canvas_atr}->yviewMoveto(0);

    my ( $start, $end ) = $self->compute_window();

    print "\n=== RENDER ===\n";
    print "start=$start end=$end\n";
    print "visible=".$self->{visible_bars}."\n";
    print "offset=".$self->{offset}."\n";

    my $price_data = $self->{market_data}->get_slice( $start, $end );
    my $atr_values = $self->{indicators}->slice_array( 'ATR', $start, $end );

    my $actual_bars = $end - $start + 1;

    $self->{scale_price}{visible_bars} = $actual_bars;
    $self->{scale_price}{offset}       = $start;

    $self->{scale_atr}{visible_bars} = $actual_bars;
    $self->{scale_atr}{offset}       = $start;

    my ( $y_min, $y_max );

    if ( $self->{view_mode} eq 'manual' ) {

        unless (
            defined $self->{y_min_manual}
            && defined $self->{y_max_manual}
        ) {
            ( $self->{y_min_manual}, $self->{y_max_manual} ) =
                $self->{price_panel}->get_y_range($price_data);
        }

        $y_min = $self->{y_min_manual};
        $y_max = $self->{y_max_manual};
    }
    else {

        ( $y_min, $y_max ) =
            $self->{price_panel}->get_y_range($price_data);

        $self->{y_min_manual} = undef;
        $self->{y_max_manual} = undef;
    }

    $self->{scale_price}{y_min} = $y_min;
    $self->{scale_price}{y_max} = $y_max;

    my ( $atr_min, $atr_max ) =
        $self->{atr_panel}->get_y_range($atr_values);

    $self->{scale_atr}{y_min} = $atr_min;
    $self->{scale_atr}{y_max} = $atr_max;

    $self->{price_panel}
        ->render(
            $self->{canvas_price},
            $price_data,
            $self->{scale_price}
        );

    $self->{atr_panel}
        ->render(
            $self->{canvas_atr},
            $atr_values,
            $self->{scale_atr}
        );

    my $timestamps = $self->compute_intraday_labels();

    $self->{price_panel}
        ->draw_time_axis(
            $self->{canvas_price},
            $timestamps
        );

    $self->{canvas_price}->delete('mode_status_indicator');

    my $text_to_show =
        $self->{view_mode} eq 'auto'
        ? "ESC: ESCALA AUTOMÁTICA"
        : "ESC: ESCALA MANUAL (Arrastre 2D habilitado)";

    my $text_color =
        $self->{view_mode} eq 'auto'
        ? '#00ff00'
        : '#ffa500';

    $self->{canvas_price}->createText(
        15, 15,
        -text   => $text_to_show,
        -fill   => $text_color,
        -anchor => 'nw',
        -font   => 'Helvetica 10 bold',
        -tags   => 'mode_status_indicator'
    );

    if ( defined $self->{_cursor_x} ) {

        my $idx_before =
            $self->{scale_price}
                 ->x_to_index_float(
                     $self->{_cursor_x}
                 );

        $self->_draw_crosshair_all(
            $self->{_cursor_x},
            $self->{_cursor_y}      // -1,
            $self->{_cursor_source} // 'price'
        );
    }
}

sub _bind_all_canvas {
    my ( $self, $event, $callback ) = @_;
    $self->{canvas_price}->CanvasBind( $event => $callback );
    $self->{canvas_atr}->CanvasBind( $event => $callback );
}

sub bind_events {
    my ($self) = @_;

    my $drag_start_x      = undef;
    my $drag_start_y      = undef;
    my $drag_start_offset = undef;
    my $drag_base_y_min   = undef;
    my $drag_base_y_max   = undef;
    my $drag_on_yscale    = 0;

    my $main_window = $self->{canvas_price}->toplevel;

    $self->_bind_all_canvas(
        '<Enter>',
        sub {
            my $canvas = shift;
            $canvas->focusForce();
        }
    );

    $self->{canvas_price}
      ->bind( '<Configure>', sub { $self->request_render(); } );
    $self->{canvas_atr}
      ->bind( '<Configure>', sub { $self->request_render(); } );

    $self->_bind_all_canvas(
        '<ButtonPress-1>',
        [
            sub {
                my ( $canvas, $x, $y ) = @_;
                $canvas->focusForce();
                $drag_start_x      = $x;
                $drag_start_y      = $y;
                $drag_start_offset = $self->{offset};
                $drag_base_y_min   = $self->{scale_price}{y_min};
                $drag_base_y_max   = $self->{scale_price}{y_max};

                my $plot_w = $self->{scale_price}->plot_width();
                $drag_on_yscale = ( $x > $plot_w ) ? 1 : 0;
                if ($drag_on_yscale) {
                    $self->{view_mode} = 'manual';
                    unless ( defined $self->{y_min_manual} ) {
                        $self->{y_min_manual} = $self->{scale_price}{y_min};
                        $self->{y_max_manual} = $self->{scale_price}{y_max};
                    }
                    $drag_base_y_min = $self->{y_min_manual};
                    $drag_base_y_max = $self->{y_max_manual};
                }
            },
            Ev('x'),
            Ev('y')
        ]
    );

    $self->_bind_all_canvas(
        '<B1-Motion>',
        [
            sub {
                my ( $canvas, $x, $y ) = @_;
                return unless defined $drag_start_x;

                if ($drag_on_yscale) {
                    my $dy    = $y - $drag_start_y;
                    my $range = $drag_base_y_max - $drag_base_y_min;
                    my $mid   = ( $drag_base_y_max + $drag_base_y_min ) / 2;
                    my $ph    = $self->{scale_price}->plot_height();
                    return if $ph == 0;

                    my $factor = 1.0 + ( $dy / $ph );
                    $factor = 0.1  if $factor < 0.1;
                    $factor = 10.0 if $factor > 10.0;

                    my $new_half = ( $range / 2 ) * $factor;
                    $self->{y_min_manual} = $mid - $new_half;
                    $self->{y_max_manual} = $mid + $new_half;
                    $self->request_render();
                    return;
                }

                my $bar_w = $self->{scale_price}->_bar_width();
                if ( $bar_w > 0 ) {
                    my $delta_bars = int( ( $x - $drag_start_x ) / $bar_w + 0.5 );
                    $self->{offset} = $drag_start_offset + $delta_bars;

                    my $size = $self->{market_data}->size();
                    $self->{offset} = 0         if $self->{offset} < 0;
                    $self->{offset} = $size - 1 if $self->{offset} > $size - 1;
                }

                if ( $self->{view_mode} eq 'manual'
                    && defined $drag_base_y_min )
                {
                    my $dy    = $y - $drag_start_y;
                    my $range = $drag_base_y_max - $drag_base_y_min;
                    my $ph    = $self->{scale_price}->plot_height();

                    if ( $ph > 0 ) {
                        my $price_shift = ( $dy / $ph ) * $range;
                        $self->{y_min_manual} = $drag_base_y_min - $price_shift;
                        $self->{y_max_manual} = $drag_base_y_max - $price_shift;
                    }
                }

                $self->request_render();
            },
            Ev('x'),
            Ev('y')
        ]
    );

    $self->_bind_all_canvas(
        '<ButtonRelease-1>',
        sub {
            $drag_start_x = undef;
            $drag_start_y = undef;
        }
    );

    $self->_bind_all_canvas(
        '<MouseWheel>',
        [
            sub {
                my ( $canvas, $delta, $x ) = @_;
                $self->{_cursor_x} = $x;
                $self->_horizontal_zoom( $delta > 0 ? -1 : 1, $x );
                $canvas->break;
            },
            Ev('D'), Ev('x')
        ]
    );

    $self->_bind_all_canvas(
        '<Button-4>',
        [
            sub {
                my ( $c, $x ) = @_;
                $self->{_cursor_x} = $x;
                $self->_horizontal_zoom( -1, $x );
                $c->break;
            },
            Ev('x')
        ]
    );

    $self->_bind_all_canvas(
        '<Button-5>',
        [
            sub {
                my ( $c, $x ) = @_;
                $self->{_cursor_x} = $x;
                $self->_horizontal_zoom( 1, $x );
                $c->break;
            },
            Ev('x')
        ]
    );

    $self->{canvas_price}->CanvasBind(
        '<ButtonPress-3>',
        [
            sub {
                my ( $canvas, $x, $y ) = @_;
                $canvas->focusForce();
                $self->{view_mode}    = 'manual';
                $self->{y_drag_start} = $y;
                $self->request_render();
            },
            Ev('x'),
            Ev('y')
        ]
    );

    $self->{canvas_price}->CanvasBind(
        '<B3-Motion>',
        [
            sub {
                my ( $canvas, $x, $y ) = @_;
                return unless defined $self->{y_drag_start};
                my $dy = $y - $self->{y_drag_start};
                $self->_vertical_drag($dy);
                $self->{y_drag_start} = $y;
            },
            Ev('x'),
            Ev('y')
        ]
    );

    $self->{canvas_price}->CanvasBind(
        '<Double-ButtonPress-3>',
        sub {
            $self->set_view_mode('auto');
        }
    );

    $self->{canvas_price}->CanvasBind(
        '<Control-Button-4>',
        [
            sub {
                my ( $c, $x ) = @_;
                $self->{_cursor_x} = $x;
                $self->_horizontal_zoom( -1, $x );
                $c->break;
            },
            Ev('x')
        ]
    );

    $self->{canvas_price}->CanvasBind(
        '<Control-Button-5>',
        [
            sub {
                my ( $c, $x ) = @_;
                $self->{_cursor_x} = $x;
                $self->_horizontal_zoom( 1, $x );
                $c->break;
            },
            Ev('x')
        ]
    );

    $self->{canvas_atr}->CanvasBind(
        '<Control-Button-4>',
        [
            sub {
                my ( $c, $x ) = @_;
                $self->{_cursor_x} = $x;
                $self->_horizontal_zoom( -1, $x );
                $c->break;
            },
            Ev('x')
        ]
    );

    $self->{canvas_atr}->CanvasBind(
        '<Control-Button-5>',
        [
            sub {
                my ( $c, $x ) = @_;
                $self->{_cursor_x} = $x;
                $self->_horizontal_zoom( 1, $x );
                $c->break;
            },
            Ev('x')
        ]
    );

    $self->{canvas_price}->CanvasBind(
        '<Motion>',
        [
            sub {
                my ( $canvas, $x, $y ) = @_;
                $self->{_cursor_x} = $x;
                $self->_draw_crosshair_all( $x, $y, 'price' );
            },
            Ev('x'),
            Ev('y')
        ]
    );

    $self->{canvas_atr}->CanvasBind(
        '<Motion>',
        [
            sub {
                my ( $canvas, $x, $y ) = @_;
                $self->{_cursor_x} = $x;
                $self->_draw_crosshair_all( $x, $y, 'atr' );
            },
            Ev('x'),
            Ev('y')
        ]
    );

    $main_window->bind( '<Key-1>', sub { $self->set_timeframe('1'); } );
    $main_window->bind( '<Key-5>', sub { $self->set_timeframe('5'); } );
    $main_window->bind( '<Key-6>', sub { $self->set_timeframe('15'); } );

    $main_window->bind( '<Key-a>', sub { $self->set_view_mode('auto'); } );
    $main_window->bind( '<Key-A>', sub { $self->set_view_mode('auto'); } );

    $main_window->bind( '<Key-m>', sub { $self->set_view_mode('manual'); } );
    $main_window->bind( '<Key-M>', sub { $self->set_view_mode('manual'); } );

    $main_window->bind( '<Key-r>', sub { $self->reset_view(); } );
    $main_window->bind( '<Key-R>', sub { $self->reset_view(); } );

    $self->{canvas_price}->focusForce();
}

sub set_view_mode {
    my ( $self, $mode ) = @_;
    $self->{view_mode} = $mode;
    if ( $mode eq 'auto' ) {
        $self->{y_min_manual} = undef;
        $self->{y_max_manual} = undef;
    }
    $self->request_render();
}

sub _horizontal_zoom {
    my ( $self, $delta ) = @_;

    my $factor   = $delta < 0 ? 0.90 : 1.10;
    my $old_bars = $self->{visible_bars};
    my $new_bars = int( $old_bars * $factor );
    my $size     = $self->{market_data}->size();

    $new_bars = 10        if $new_bars < 10;
    $new_bars = $size - 1 if $new_bars > $size - 1;
    $new_bars = 1         if $new_bars < 1;

    return if $new_bars == $old_bars;

    my $anchor_idx = $self->{_cursor_idx_float};

    my $snap_before =
        $self->{scale_price}
             ->index_to_center_x($anchor_idx);

    my $pw = $self->{scale_price}->plot_width();

    if ( defined $anchor_idx && $pw > 0 ) {

        my ( $start, $end ) = $self->compute_window();

        my $old_bw = $self->{scale_price}->bar_width();
        return if $old_bw <= 0;

        my $snap_x =
            ( $anchor_idx - $start ) * $old_bw
            + $old_bw / 2.0;

        $self->{visible_bars} = $new_bars;

        $self->{scale_price}{visible_bars} = $new_bars;

        my $new_bw = $self->{scale_price}->bar_width();
        return if $new_bw <= 0;

        my $new_start_f =
            $anchor_idx
            - ( $snap_x - $new_bw / 2.0 ) / $new_bw;

        my $new_end_f =
            $new_start_f + $new_bars - 1;

        if ( $new_end_f > $size - 1 ) {

            my $overflow = $new_end_f - ($size - 1);

            my $clamped_start =
                ($size - 1)
                - $new_bars
                + 1;

            print "\n*** RIGHT EDGE HIT ***\n";
            print "anchor_idx=$anchor_idx\n";
            print "new_start_f=$new_start_f\n";
            print "new_end_f=$new_end_f\n";
            print "visible_bars=$new_bars\n";
            print "overflow=$overflow\n";
            print "clamped_start=$clamped_start\n";
            print "start_shift=".($clamped_start - $new_start_f)."\n";
        }

        my $new_offset =
            ( $size - 1 ) - $new_end_f;

        $new_offset = 0
            if $new_offset < 0;

        $new_offset = $size - 1
            if $new_offset > $size - 1;

        $self->{offset} = $new_offset;

        my ( $final_start, $final_end ) =
            $self->compute_window();

        my $tmp_scale = $self->{scale_price};

        $tmp_scale->{offset} = $final_start;

        my $snap_after =
            $tmp_scale->index_to_center_x(
                $anchor_idx
            );

        print "\n=== ZOOM ===\n";
        print "offset_before=".$self->{offset}."\n";

        print "anchor_idx=".$anchor_idx."\n";

        print "snap_before=".$snap_before."\n";
        print "snap_after=".$snap_after."\n";

        print "delta="
              . ($snap_after - $snap_before)
              . "\n";

        print "new_start_f=".$new_start_f."\n";
        print "new_end_f=".$new_end_f."\n";
        print "new_offset=".$new_offset."\n";

        print "size_minus_1="
              . ($size - 1)
              . "\n";

        print "final_start=".$final_start."\n";
        print "final_end=".$final_end."\n";


    }
    else {

        $self->{visible_bars} = $new_bars;

        $self->{offset} = 0
            if $self->{offset} < 0;

        $self->{offset} = $size - 1
            if $self->{offset} > $size - 1;
    }

    $self->request_render();
}

sub _vertical_drag {
    my ( $self, $dy ) = @_;
    my $scale = $self->{scale_price};

    unless ( defined $self->{y_min_manual} ) {
        $self->{y_min_manual} = $scale->{y_min};
        $self->{y_max_manual} = $scale->{y_max};
    }

    my $range = $self->{y_max_manual} - $self->{y_min_manual};
    my $ph    = $scale->plot_height();
    return if $ph == 0;

    my $price_shift = ( $dy / $ph ) * $range;
    $self->{y_min_manual} -= $price_shift;
    $self->{y_max_manual} -= $price_shift;
    $self->request_render();
}

sub _vertical_zoom {
    my ( $self, $factor ) = @_;
    my $scale = $self->{scale_price};

    unless ( defined $self->{y_min_manual} ) {
        $self->{y_min_manual} = $scale->{y_min};
        $self->{y_max_manual} = $scale->{y_max};
    }

    my $mid  = ( $self->{y_min_manual} + $self->{y_max_manual} ) / 2;
    my $half = ( $self->{y_max_manual} - $self->{y_min_manual} ) / 2;

    $half *= $factor;
    $self->{y_min_manual} = $mid - $half;
    $self->{y_max_manual} = $mid + $half;
    $self->request_render();
}

sub _draw_crosshair_all {
    my ( $self, $x, $y, $source ) = @_;

    $self->{_cursor_x} = $x;

    my $idx    = $self->{scale_price}->x_to_index($x);
    my $snap_x = $self->{scale_price}->index_to_center_x($idx);

    $self->{_cursor_idx}    = $idx;
    $self->{_cursor_idx_float} = $self->{scale_price}->x_to_index_float($x);
    $self->{_cursor_snap_x} = $snap_x;
    $self->{_cursor_y}      = $y;
    $self->{_cursor_source} = $source;

    my $ts       = $self->{market_data}->get_timestamp($idx);
    my $time_str = '';
    if ( defined $ts ) {
        my @t = localtime($ts);
        $time_str =
          sprintf( "%02d/%02d %02d:%02d", $t[3], $t[4] + 1, $t[2], $t[1] );
    }

    my $price_y = $source eq 'price' ? $y : -1;
    my $atr_y   = $source eq 'atr'   ? $y : -1;

    $self->{price_panel}->draw_crosshair( $snap_x, $price_y,
        $source eq 'price' ? $time_str : '' );
    $self->{atr_panel}
      ->draw_crosshair( $snap_x, $atr_y, $source eq 'atr' ? $time_str : '' );
}

sub set_timeframe {
    my ( $self, $tf ) = @_;
    $self->{market_data}->set_timeframe($tf);
    $self->{indicators}->reset_all();
    $self->{indicators}->update_last( $self->{market_data} );
    $self->reset_view();
}

sub reset_view {
    my ($self) = @_;
    $self->{offset}          = 0;
    $self->{view_mode}       = 'auto';
    $self->{y_min_manual}    = undef;
    $self->{y_max_manual}    = undef;
    $self->{visible_bars}    = 100;
    $self->{_zoom_anchor_idx} = undef;
    $self->{_zoom_anchor_x}   = undef;
    $self->{_cursor_x}        = undef;
    $self->request_render();
}

sub compute_intraday_labels {
    my ($self) = @_;
    my ( $start, $end ) = $self->compute_window();

    my $visible  = $end - $start + 1;
    my $n_labels = 6;
    my $step     = int( $visible / $n_labels ) || 1;

    my @labels;
    my $prev_day = undef;
    my $i_start  = $start < 0 ? 0 : $start;

    my %is_day_pivot;
    my $last_day = undef;
    for my $i ( $i_start .. $end ) {
        my $ts = $self->{market_data}->get_timestamp($i);
        next unless defined $ts;
        my @t   = localtime($ts);
        my $day = $t[3];
        if ( !defined $last_day || $day != $last_day ) {
            $is_day_pivot{$i} = sprintf( "%02d/%02d", $t[3], $t[4] + 1 );
            $last_day = $day;
        }
    }

    my %used_idx;
    for ( my $i = $i_start ; $i <= $end ; $i += $step ) {
        my $ts = $self->{market_data}->get_timestamp($i);
        next unless defined $ts;

        if ( exists $is_day_pivot{$i} ) {
            push @labels, [ $i, $is_day_pivot{$i} ];
        }
        else {
            my @t = localtime($ts);
            push @labels, [ $i, sprintf( "%02d:%02d", $t[2], $t[1] ) ];
        }
        $used_idx{$i} = 1;
    }

    for my $i ( sort { $a <=> $b } keys %is_day_pivot ) {
        next if $used_idx{$i};

        my $too_close = 0;
        for my $used ( keys %used_idx ) {
            if ( abs( $used - $i ) < int( $step / 2 ) ) {
                $too_close = 1;
                last;
            }
        }

        if ($too_close) {
            @labels = grep { abs( $_->[0] - $i ) >= int( $step / 2 ) } @labels;
        }
        push @labels, [ $i, $is_day_pivot{$i} ];
        $used_idx{$i} = 1;
    }

    my $last_idx = $self->{market_data}->last_index();
    if ( $last_idx >= $start && $last_idx <= $end ) {
        my $ts = $self->{market_data}->get_timestamp($last_idx);
        if ( defined $ts ) {
            my @t     = localtime($ts);
            my $label = sprintf( "%02d/%02d", $t[3], $t[4] + 1 );
            @labels = grep { $_->[0] != $last_idx } @labels;
            push @labels, [ $last_idx, $label ];
        }
    }

    @labels = sort { $a->[0] <=> $b->[0] } @labels;

    return \@labels;
}

sub get_all_timestamps {
    my ($self) = @_;
    my ( $start, $end ) = $self->compute_window();
    my @result;
    for my $i ( $start .. $end ) {
        my $ts = $self->{market_data}->get_timestamp($i);
        push @result, [ $i, $ts ] if defined $ts;
    }
    return \@result;
}

1;