package Market::Panels::Scales;
use strict;
use warnings;

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        canvas_width       => $args{canvas_width}       // 800,
        canvas_height      => $args{canvas_height}      // 400,
        margin_right       => $args{margin_right}       // 60,
        margin_bottom      => $args{margin_bottom}      // 20,
        visible_bars       => $args{visible_bars}       // 100,
        right_padding_bars => $args{right_padding_bars} // 8,
        offset             => $args{offset}             // 0,
        y_min              => $args{y_min}              // 0,
        y_max              => $args{y_max}              // 1,
    };
    bless $self, $class;
    return $self;
}

sub plot_width {
    my ($self) = @_;
    return $self->{canvas_width} - $self->{margin_right};
}

sub plot_height {
    my ($self) = @_;
    return $self->{canvas_height} - $self->{margin_bottom};
}

# ─── bar_width ────────────────────────────────────────────────────────────────
# Ancho de barra en píxeles para los visible_bars actuales.
# right_px: espacio fijo reservado a la derecha del área de plot (no en barras).
# Si usable quedara menor al 50% del plot, se usa 85% del plot como fallback.
sub bar_width {
    my ($self) = @_;
    return $self->bar_width_for( $self->{visible_bars} );
}

# ─── bar_width_for ────────────────────────────────────────────────────────────
# Calcula el ancho de barra para un número arbitrario de barras.
# Centraliza la fórmula para que _zoom_cursor no la duplique.
sub bar_width_for {
    my ( $self, $n_bars ) = @_;
    my $pw       = $self->plot_width();
    my $right_px = 60;
    my $usable   = $pw - $right_px;
    $usable      = $pw * 0.85 if $usable < $pw * 0.5;
    return $n_bars > 0 ? $usable / $n_bars : 1;
}

sub _plot_width  { return $_[0]->plot_width(); }
sub _plot_height { return $_[0]->plot_height(); }
sub _bar_width   { return $_[0]->bar_width(); }

# ─── Conversiones de coordenadas ─────────────────────────────────────────────

sub index_to_x {
    my ( $self, $index ) = @_;
    my $rel = $index - $self->{offset};
    return $rel * $self->bar_width();
}

sub x_to_index {
    my ( $self, $x ) = @_;
    my $bw = $self->bar_width();
    return $bw > 0 ? int( $x / $bw ) + $self->{offset} : $self->{offset};
}

sub x_to_index_float {
    my ( $self, $x ) = @_;
    my $bw = $self->bar_width();
    return $bw > 0 ? ( $x / $bw ) + $self->{offset} : $self->{offset};
}

sub index_to_center_x {
    my ( $self, $index ) = @_;
    return $self->index_to_x($index) + $self->bar_width() / 2;
}

sub value_to_y {
    my ( $self, $value ) = @_;
    my $range = $self->{y_max} - $self->{y_min};
    return $self->plot_height() / 2 if $range == 0;
    my $ratio = ( $value - $self->{y_min} ) / $range;
    return $self->plot_height() * ( 1 - $ratio );
}

sub y_to_value {
    my ( $self, $y ) = @_;
    my $range = $self->{y_max} - $self->{y_min};
    return $self->{y_min} if $range == 0;
    my $ratio = 1 - ( $y / $self->plot_height() );
    return $self->{y_min} + $ratio * $range;
}

sub _draw_y_scale {
    my ( $self, $canvas, $n_labels ) = @_;

    my $range = $self->{y_max} - $self->{y_min};
    return if $range == 0;

    my $tick    = 0.25;
    my $pw      = $self->plot_width();
    my $x_label = $self->{canvas_width} - $self->{margin_right} + 4;
    my $min_px  = 14;

    my $first = int( $self->{y_min} / $tick ) * $tick;
    $first += $tick if $first < $self->{y_min};

    my $prev_y = undef;
    my $v      = $first;

    while ( $v <= $self->{y_max} + 1e-9 ) {
        my $y = $self->value_to_y($v);

        if ( !defined $prev_y || abs( $y - $prev_y ) >= $min_px ) {
            $canvas->createLine(
                0, $y, $pw, $y,
                -fill => '#2a2a2a',
                -dash => [ 2, 4 ],
                -tags => ['scale_y'],
            );
            $canvas->createText(
                $x_label, $y,
                -text   => sprintf( "%.2f", $v ),
                -anchor => 'w',
                -fill   => '#888888',
                -font   => [ 'monospace', 8 ],
                -tags   => ['scale_y'],
            );
            $prev_y = $y;
        }
        $v = int( ( $v + $tick ) / $tick + 0.5 ) * $tick;
    }
}

1;