#!/usr/bin/perl

use strict;
use warnings;

use Tickit;
use Tickit::Widgets qw( VBox HBox Button Static GridBox CheckButton RadioButton );

use Data::Bitfield qw( bitfield boolfield intfield );
use Device::BusPirate;
use Getopt::Long;

# All the ->add code is nicer if you can chain calls
{
   # TODO: This should be in Tickit itself
   my $old_add = Tickit::ContainerWidget->can( 'add' );
   no strict 'refs'; no warnings 'redefine';
   *Tickit::ContainerWidget::add = sub {
      my $self = shift;
      $self->$old_add( @_ );
      return $self;
   };
}

Tickit::Style->load_style( <<'EOF' );
HBox { spacing: 1; }

RadioButton { spacing: 1; }

CheckButton:active { fg: "green"; check-fg: "green"; }
RadioButton:active { fg: "green"; tick-fg: "green"; }
EOF

GetOptions(
   'p|pirate=s' => \my $PIRATE,
   'b|baud=i'   => \my $BAUD,
) or exit 1;

my $pirate = Device::BusPirate->new(
   serial => $PIRATE,
   baud   => $BAUD,
);
END { $pirate and $pirate->stop; }

my $avr = $pirate->mount_chip( "AVR_HVSP" )->get;

$avr->start->get;
END { $avr and $avr->stop->get; }

my $tickit = Tickit->new(
   root => Tickit::Widget::VBox->new( spacing => 1 )
      ->add( Tickit::Widget::Static->new(
            text => "Device: " . $avr->partname ),
      )
      ->add( Tickit::Widget::HBox->new( spacing => 2 )
         ->add( Tickit::Widget::Button->new(
               label => "Default",
               on_click => \&default_fuses,
            ), expand => 1 )
         ->add( Tickit::Widget::Button->new(
               label => "Read",
               on_click => \&read_fuses,
            ), expand => 1 )
         ->add( Tickit::Widget::Button->new(
               label => "Write",
               on_click => \&write_fuses,
            ), expand => 1 )
      )
      ->add( my $fusegrid = Tickit::Widget::GridBox->new(
            col_spacing => 2,
         ), expand => 1 )
);

my %fuses; # $name => [ $value, $on_read ]

sub def_fuse
{
   my ( $name ) = @_;

   my $row = $fusegrid->rowcount;
   $fusegrid->add( $row, 0,
      Tickit::Widget::Static->new(
         text => $name,
      )
   );

   return $row;
}

sub def_boolfuse
{
   my ( $name ) = @_;
   my $row = def_fuse( $name );

   $fusegrid->add( $row, 1,
      my $check = Tickit::Widget::CheckButton->new(
         label => "",
         on_toggle => sub {
            $fuses{$name}[0] = !$_[1];
         },
      )
   );

   $fuses{$name}[1] = sub { $_[0] ? $check->deactivate : $check->activate };
}

sub def_intfuse
{
   my ( $name, @values ) = @_;
   my $row = def_fuse( $name );

   $fusegrid->add( $row, 1,
      my $hbox = Tickit::Widget::HBox->new
   );

   my $group = Tickit::Widget::RadioButton::Group->new;
   my %buttons;

   foreach my $i ( 0 .. $#values ) {
      my $label = $values[$i];
      next if $label eq ".";
      next if $buttons{$label};

      $hbox->add( $buttons{$label} = Tickit::Widget::RadioButton->new(
            label => $label,
            group => $group,
            value => $i,
      ) );
   }

   $group->set_on_changed( sub {
      my ( undef, $value ) = @_;
      $fuses{$name}[0] = $value;
   });

   $fuses{$name}[1] = sub {
      my $value = $values[$_[0]];
      $buttons{$value}->activate if $buttons{$value};
   };
}

# EFUSE
bitfield EFUSE =>
   SELFPRGEN => boolfield(0);

def_boolfuse SELFPRGEN =>;

# HFUSE
bitfield HFUSE =>
   RSTDISBL => boolfield(7),
   DWEN     => boolfield(6),
   SPIEN    => boolfield(5),
   WDTON    => boolfield(4),
   EESAVE   => boolfield(3),
   BODLEVEL => intfield(0,3);

def_boolfuse RSTDISBL  =>;
def_boolfuse DWEN      =>;
def_boolfuse SPIEN     =>;
def_boolfuse WDTON     =>;
def_boolfuse EESAVE    =>;
def_intfuse  BODLEVEL  => qw( . . . . 4.3V 2.7V 1.8V DISABLED );

# LFUSE
bitfield LFUSE =>
   CKDIV8   => boolfield(7),
   CKOUT    => boolfield(6),
   SUT      => intfield(4,2),
   CKSEL    => intfield(0,4);

def_boolfuse CKDIV8    =>;
def_boolfuse CKOUT     =>;

# SUT and CKSEL are inter-related. The interpretation of SUT depends on the
# choice of CKSEL
{
   my $sutrow = def_fuse SUT =>;
   my $ckselrow = def_fuse CKSEL =>;
   my $cksel0row = def_fuse CKSEL0 =>;

   $fusegrid->add( $sutrow, 1,
      my $suthbox = Tickit::Widget::HBox->new
   );

   $fusegrid->add( $ckselrow, 1,
      Tickit::Widget::VBox->new
         ->add( my $hbox1 = Tickit::Widget::HBox->new )
         ->add( my $hbox2 = Tickit::Widget::HBox->new )
   );

   my @cksel_labels = qw(
      EXT INT8M INT128K XTAL_LF
      0.4-0.9M 0.9-3M 3-8M 8M+
   );

   my $ckselgroup = Tickit::Widget::RadioButton::Group->new;
   my @cksel_buttons;
   ( $_ < 4 ? $hbox1 : $hbox2 )->add(
      $cksel_buttons[@cksel_buttons] = Tickit::Widget::RadioButton->new(
         label => $cksel_labels[$_],
         group => $ckselgroup,
         value => $_ << 1,
      )
   ) for 0 .. 7;

   $ckselgroup->set_on_changed( sub {
      my ( undef, $value ) = @_;
      my $cksel =($fuses{CKSEL}[0] & 0x01) | $value;
      return if $cksel == $fuses{CKSEL}[0];

      $fuses{CKSEL}[0] = $cksel;
      $fuses{CKSEL}[1]->( $cksel );
   });

   my $cksel0button = Tickit::Widget::CheckButton->new(
      label => "",
      on_toggle => sub {
         my ( undef, $active ) = @_;
         my $cksel = ($fuses{CKSEL}[0] & 0x0e) | ($active ? 1 : 0);
         return if $cksel == $fuses{CKSEL}[0];

         $fuses{CKSEL}[0] = $cksel;
         $fuses{CKSEL}[1]->( $cksel );
      },
   );

   my %sut_labels = (
      0 => [qw( 6CK/14CK 6CK/14CK+4ms 6CK/14CK+64ms )],
      2 => [qw( 6CK/14CK 6CK/14CK+4ms 6CK/14CK+64ms )],
      4 => [qw( 6CK/14CK 6CK/14CK+4ms 6CK/14CK+64ms )],
      6 => [qw( 1KCK/4ms 1KCK/64ms 32KCK/64ms )],

      8 => [qw( 258CK/14CK+4ms 258CK/14CK+64ms 1KCK/14CK 1KCK/14CK+4ms )],
      9 => [qw( 1KCK/14CK+64ms 16KCK/14CK 16KCK/14CK+4ms 16KCK/14CK+64ms )],
   );

   # Only once we have a CKSEL can we set the labels of SUT
   $fuses{CKSEL}[1] = sub {
      my ( $cksel ) = @_;

      $cksel & 0x01 ? $cksel0button->activate : $cksel0button->deactivate;
      $_->value == ($cksel & 0xe) and $_->activate, last for @cksel_buttons;

      $suthbox->remove( $_ ) for $suthbox->children;

      my $sutgroup = Tickit::Widget::RadioButton::Group->new;

      # All crystal values use the same setting
      if( $cksel & 0x08 ) {
         $cksel &= 0x09;
         $fusegrid->add( $cksel0row, 1, $cksel0button ) if !$cksel0button->parent;
      }
      else {
         $fusegrid->remove( $cksel0row, 1 ) if $cksel0button->parent;
      }

      my @labels = @{ $sut_labels{$cksel} };
      my $sut = $fuses{SUT}[0];
      foreach my $i ( 0 .. $#labels ) {
         $suthbox->add( my $button = Tickit::Widget::RadioButton->new(
            label => $labels[$i],
            value => $i,
            group => $sutgroup,
         ) );
         $button->activate if $sut == $i;
      }

      $sutgroup->set_on_changed( sub {
         my ( undef, $sut ) = @_;
         $fuses{SUT}[0] = $sut;
      });
   };
}

sub default_fuses
{
   # These from the ATtiny24/44/84 data sheet
   my %fusevals = (
      SELFPRGEN => 1,
      RSTDISBL  => 1,
      DWEN      => 1,
      SPIEN     => 0,
      WDTON     => 1,
      EESAVE    => 1,
      BODLEVEL  => 0x07,
      CKDIV8    => 0,
      CKOUT     => 1,
      SUT       => 0x02,
      CKSEL     => 0x02,
   );

   $fuses{$_}[0] = $fusevals{$_} for keys %fusevals;

   foreach my $name ( keys %fusevals ) {
      $fuses{$name}[1]->( $fusevals{$name} ) if $fuses{$name}[1];
   }
}

sub read_fuses
{
   my %fusevals = (
      unpack_LFUSE( ord $avr->read_lfuse->get ),
      unpack_HFUSE( ord $avr->read_hfuse->get ),
      unpack_EFUSE( ord $avr->read_efuse->get ),
   );

   $fuses{$_}[0] = $fusevals{$_} for keys %fusevals;

   foreach my $name ( keys %fusevals ) {
      $fuses{$name}[1]->( $fusevals{$name} ) if $fuses{$name}[1];
   }
}

sub write_fuses
{
   $avr->write_lfuse( chr pack_LFUSE(
      map { $_ => $fuses{$_}[0] } qw( CKDIV8 CKOUT SUT CKSEL )
   ) )->get;

   $avr->write_hfuse( chr pack_HFUSE(
      map { $_ => $fuses{$_}[0] } qw( RSTDISBL DWEN SPIEN WDTON EESAVE BODLEVEL )
   ) )->get;

   $avr->write_efuse( chr (pack_EFUSE(
      map { $_ => $fuses{$_}[0] } qw( SELFPRGEN )
   ) | 0xFE) )->get;
}

$tickit->run;
