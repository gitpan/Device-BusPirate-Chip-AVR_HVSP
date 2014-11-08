#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2014 -- leonerd@leonerd.org.uk

package Device::BusPirate::Chip::AVR_HVSP;

use strict;
use warnings;
use base qw( Device::BusPirate::Chip );

our $VERSION = '0.02';

use Carp;

use Future::Utils qw( repeat );
use Struct::Dumb qw( readonly_struct );

use constant CHIP => "AVR_HVSP";
use constant MODE => "BB";

readonly_struct PartInfo   => [qw( signature flash_words flash_pagesize eeprom_words eeprom_pagesize has_efuse )];
readonly_struct MemoryInfo => [qw( wordsize pagesize words can_write )];

=head1 NAME

C<Device::BusPirate::Chip::AVR_HVSP> - high-voltage serial programming for F<AVR> chips

=head1 DESCRIPTION

This L<Device::BusPirate::Chip> subclass allows interaction with an F<AVR>
microcontroller of the F<ATtiny> family in high-voltage serial programming
(HVSP) mode. It is particularly useful for configuring fuses or working with a
chip with the C<RSTDISBL> fuse programmed, because in such cases a regular ISP
programmer cannot be used.

=head2 CONNECTIONS

To use this module, make the following connections between the F<Bus Pirate>
(with colours of common cable types), and the F<ATtiny> chip (with example pin
numbers for some common devices):

  Bus Pirate | Sparkfun | Seeed    |:| ATtiny | tiny84 | tiny85
  -----------+----------+----------+-+--------+--------+-------
  MISO       | brown    | black    |:|    SDO |      9 |      7
  CS         | red      | white    |:|    SII |      8 |      6
  MOSI       | orange   | grey     |:|    SDI |      7 |      5
  CLK        | yellow   | purple   |:|    SCI |      2 |      2
  AUX        | green    | blue     |:| +12V supply - see below
             |          |          |:|  RESET |      4 |      1
  +5V        | grey     | orange   |:|    Vcc |      1 |      8
  GND        | black    | brown    |:|    GND |     14 |      4

The C<AUX> line from the F<Bus Pirate> will need to be able to control a +12V
supply to the C<RESET> pin of the F<ATtiny> chip. It should be active-high,
and can be achieved by a two-stage NPN-then-PNP transistor arrangement.

Additionally, the C<SDO> pin and the C<PA0> to C<PA2> pins of 14-pin devices
will need a pull-down to ground of around 100Ohm to 1kOhm.

=cut

=head1 METHODS

The following methods documented with a trailing call to C<< ->get >> return
L<Future> instances.

=cut

# TODO: This needs to be migrated to Device::BusPirate itself
sub _enter_mutex
{
   my $self = shift;
   my ( $code ) = @_;

   my $oldmtx = $self->{mutex} // $self->pirate->_new_future->done( $self );
   $self->{mutex} = my $newmtx = $self->pirate->_new_future;

   $oldmtx->then( $code )
      ->then_with_f( sub {
         my $f = shift;
         $newmtx->done( $self );
         $f
      });
}

my $SDI = "mosi";
my $SII = "cs";
my $SCI = "clk";
my $SDO = "miso";

sub mount
{
   my $self = shift;
   my ( $mode ) = @_;

   $self->SUPER::mount( $mode )
      ->then( sub {
         $mode->configure(
            open_drain => 0,
         );
      })
      ->then( sub {
         $mode->write(
            $SDI => 0,
            $SII => 0,
            $SCI => 0,
         );
      })
      ->then( sub {
         # Set input
         $mode->read_miso;
      });
}

=head2 $chip->start->get

Powers up the device, reads and checks the signature, ensuring it is a
recognised chip.

=cut

my %PARTS = (
   #                     Sig       Flash sz  Eeprom sz  EF
   ATtiny24 => PartInfo( "1E910B", 1024, 16,   128, 4,  1 ),
   ATtiny44 => PartInfo( "1E9207", 2048, 16,   256, 4,  1 ),
   ATtiny84 => PartInfo( "1E930C", 4096, 32,   512, 4,  1 ),

   ATtiny13 => PartInfo( "1E9007",  512, 16,    64, 4,  0 ),
   ATtiny25 => PartInfo( "1E9108", 1024, 16,   128, 4,  1 ),
   ATtiny45 => PartInfo( "1E9206", 2048, 32,   256, 4,  1 ),
   ATtiny85 => PartInfo( "1E930B", 4096, 32,   512, 4,  1 ),
);

sub start
{
   my $self = shift;

   # Allow power to settle before turning on +12V on AUX
   # Normal serial line overheads should allow enough time here

   $self->power(1)->then( sub {
      $self->aux(1)
   })->then( sub {
      $self->read_signature;
   })->then( sub {
      my ( $sig ) = @_;
      $sig = uc unpack "H*", $sig;

      my $partinfo;
      my $part;
      ( $partinfo = $PARTS{$_} )->signature eq $sig and $part = $_, last
         for keys %PARTS;

      defined $part or return Future->fail( "Unrecognised signature $sig" );

      $self->{part}     = $part;
      $self->{partinfo} = $partinfo;

      # ARRAYref so we keep this nice order
      $self->{memories} = [
         #                          ws ps nw wr
         signature   => MemoryInfo(  8, 3, 3, 0 ),
         calibration => MemoryInfo(  8, 1, 1, 0 ),
         lock        => MemoryInfo(  8, 1, 1, 1 ),
         lfuse       => MemoryInfo(  8, 1, 1, 1 ),
         hfuse       => MemoryInfo(  8, 1, 1, 1 ),
         ( $partinfo->has_efuse ?
            ( efuse  => MemoryInfo(  8, 1, 1, 1 ) ) :
            () ),
         flash       => MemoryInfo( 16, $partinfo->flash_pagesize, $partinfo->flash_words, 1 ),
         eeprom      => MemoryInfo(  8, $partinfo->eeprom_pagesize, $partinfo->eeprom_words, 1 ),
      ];

      return Future->done( $self );
   });
}

=head2 $chip->stop->get

Shut down power to the device.

=cut

sub stop
{
   my $self = shift;

   Future->needs_all(
      $self->power(0),
      $self->aux(0),
   );
}

=head2 $name = $chip->partname

Returns the name of the chip whose signature was detected by the C<start>
method.

=cut

sub partname
{
   my $self = shift;
   return $self->{part};
}

=head2 $memory = $avr->memory_info( $name )

Returns a memory info structure giving details about the named memory for the
attached part. The following memory names are recognised:

 signature calibration lock lfuse hfuse efuse flash eeprom

(Note that the F<ATtiny13> has no C<efuse> memory).

The structure will respond to the following methods:

=over 4

=item * wordsize

Returns number of bits per word. This will be 8 for the byte-oriented
memories, but 16 for the main program flash.

=item * pagesize

Returns the number of words per page; the smallest amount that can be
written in one go.

=item * words

Returns the total number of words that are available.

=item * can_write

Returns true if the memory type can be written (in general; this does not take
into account the lock bits that might futher restrict a particular chip).

=back

=cut

sub memory_info
{
   my $self = shift;
   my ( $name ) = @_;

   my $memories = $self->{memories};
   $memories->[$_*2] eq $name and return $memories->[$_*2 + 1]
      for 0 .. $#$memories/2;

   die "$self->{part} does not have a $name memory";
}

=head2 %memories = $avr->memory_infos

Returns a key/value list of all the known device memories.

=cut

sub memory_infos
{
   my $self = shift;
   return @{ $self->{memories} };
}

sub _transfer
{
   my $self = shift;

   my ( $sdi, $sii ) = @_;

   my $sdo = 0;
   my $mode = $self->mode;

   # A "byte" transfer consists of 11 clock transitions; idle low. Each bit is
   # clocked in from SDO on the falling edge of clocks 0 to 7, but clocked out
   # of SDI and SII on clocks 1 to 8.
   # We'll therefore toggle the clock 11 times; on each of the first 8 clocks
   # we raise it, then simultaneously lower it, writing out the next out bits
   # and reading in the input.
   # Serial transfer is MSB first in both directions
   #
   # We cheat massively here and rely on pipeline ordering of the actual
   # ->write calls, by writing all 22 of the underlying bytes to the Bus
   # Pirate serial port, then waiting on all 22 bytes to come back.

   Future->needs_all( map {
      my $mask = $_ < 8 ? (1 << 7-$_) : 0;

      Future->needs_all(
         $mode->write( $SCI => 1 ),

         $mode->writeread(
            $SDI => ( $sdi & $mask ),
            $SII => ( $sii & $mask ),
            $SCI => 0
         )->on_done( sub {
            $sdo |= $mask if shift->{$SDO};
         })
      )
   } 0 .. 10 )
      ->then( sub { Future->done( $sdo ) } );
}

sub _await_SDO_high
{
   my $self = shift;

   my $mode = $self->mode;

   my $count = 50;
   repeat {
      $count-- or return Future->fail( "Timeout waiting for device to ACK" );

      $mode->${\"read_$SDO"}
   } until => sub { $_[0]->failure or $_[0]->get };
}

# The AVR datasheet on HVSP does not name any of these operations, only
# giving them bit patterns. We'll use the names invented by RikusW. See also
#   https://sites.google.com/site/megau2s/

use constant {
   # SII values
   HVSP_CMD  => 0x4C, # Command
   HVSP_LLA  => 0x0C, # Load Lo Address
   HVSP_LHA  => 0x1C, # Load Hi Address
   HVSP_LLB  => 0x2C, # Load Lo Byte
   HVSP_LHB  => 0x3C, # Load Hi Byte
   HVSP_WLB  => 0x64, # Write Lo Byte = WRL = WFU0
   HVSP_WHB  => 0x74, # Write Hi Byte = WRH = WFU1
   HVSP_WFU2 => 0x66, # Write Extended Fuse
   HVSP_RLB  => 0x68, # Read Lo Byte
   HVSP_RHB  => 0x78, # Read Hi Byte
   HVSP_RSIG => 0x68, # Read Signature
   HVSP_RFU0 => 0x68, # Read Low Fuse
   HVSP_RFU1 => 0x7A, # Read High Fuse
   HVSP_RFU2 => 0x6A, # Read Extended Fuse
   HVSP_REEP => 0x68, # Read EEPROM
   HVSP_ROSC => 0x78, # Read Oscillator calibration
   HVSP_RLCK => 0x78, # Read Lock
   HVSP_PLH  => 0x7D, # Program (?) Hi
   HVSP_PLL  => 0x6D, # Program (?) Lo
   HVSP_ORM  => 0x0C, # OR mask for SII to pulse actual read/write operation

   # HVSP_CMD Commands
   CMD_CE     => 0x80, # Chip Erase
   CMD_WFUSE  => 0x40, # Write Fuse
   CMD_WLOCK  => 0x20, # Write Lock
   CMD_WFLASH => 0x10, # Write FLASH
   CMD_WEEP   => 0x11, # Write EEPROM
   CMD_RSIG   => 0x08, # Read Signature
   CMD_RFUSE  => 0x04, # Read Fuse
   CMD_RFLASH => 0x02, # Read FLASH
   CMD_REEP   => 0x03, # Read EEPROM
   CMD_ROSC   => 0x08, # Read Oscillator calibration
   CMD_RLOCK  => 0x04, # Read Lock
};
# Some synonyms not found in the AVR ctrlstack software
use constant {
   HVSP_WLCK => HVSP_WLB, # Write Lock
   HVSP_WFU0 => HVSP_WLB, # Write Low Fuse
   HVSP_WFU1 => HVSP_WHB, # Write High Fuse
};

=head2 $avr->chip_erase->get

Performs an entire chip erase. This will clear the flash and EEPROM memories,
before resetting the lock bits. It does not affect the fuses.

=cut

sub chip_erase
{
   my $self = shift;

   $self->_transfer( CMD_CE, HVSP_CMD )
      ->then( sub { $self->_transfer( 0, HVSP_WLB ) })
      ->then( sub { $self->_transfer( 0, HVSP_WLB|HVSP_ORM ) })
      ->then( sub { $self->_await_SDO_high });
}

=head2 $bytes = $avr->read_signature->get

Reads the three device signature bytes and returns them in as a single binary
string.

=cut

sub read_signature
{
   my $self = shift;

   $self->_transfer( CMD_RSIG, HVSP_CMD )->then( sub {
      my @sig;
      repeat {
         my $byte = shift;
         $self->_transfer( $byte, HVSP_LLA )
            ->then( sub { $self->_transfer( 0, HVSP_RSIG ) } )
            ->then( sub { $self->_transfer( 0, HVSP_RSIG|HVSP_ORM ) } )
            ->on_done( sub { $sig[$byte] = shift; } );
      } foreach => [ 0 .. 2 ],
        otherwise => sub { Future->done( pack "C*", @sig ) };
   })
}

=head2 $byte = $avr->read_calibration->get

Reads the calibration byte.

=cut

sub read_calibration
{
   my $self = shift;

   $self->_transfer( CMD_ROSC, HVSP_CMD )
      ->then( sub { $self->_transfer( 0, HVSP_LLA ) } )
      ->then( sub { $self->_transfer( 0, HVSP_ROSC ) } )
      ->then( sub { $self->_transfer( 0, HVSP_ROSC|HVSP_ORM ) } )
      ->then( sub {
         Future->done( chr $_[0] )
      });
}

=head2 $byte = $avr->read_lock->get

Reads the lock byte.

=cut

sub read_lock
{
   my $self = shift;

   $self->_transfer( CMD_RLOCK, HVSP_CMD )
      ->then( sub { $self->_transfer( 0, HVSP_RLCK ) } )
      ->then( sub { $self->_transfer( 0, HVSP_RLCK|HVSP_ORM ) } )
      ->then( sub {
         my ( $byte ) = @_;
         Future->done( chr( $byte & 3 ) );
      });
}

=head2 $avr->write_lock( $byte )->get

Writes the lock byte.

=cut

sub write_lock
{
   my $self = shift;
   my ( $byte ) = @_;

   $self->_transfer( CMD_WLOCK, HVSP_CMD )
      ->then( sub { $self->_transfer( ( ord $byte ) & 3, HVSP_LLB ) })
      ->then( sub { $self->_transfer( 0, HVSP_WLCK ) })
      ->then( sub { $self->_transfer( 0, HVSP_WLCK|HVSP_ORM ) })
      ->then( sub { $self->_await_SDO_high });
}

=head2 $int = $avr->read_fuse_byte( $fuse )->get

Reads one of the fuse bytes C<lfuse>, C<hfuse>, C<efuse>, returning an
integer.

=cut

my %SII_FOR_FUSE_READ = (
   lfuse => HVSP_RFU0,
   hfuse => HVSP_RFU1,
   efuse => HVSP_RFU2,
);

sub read_fuse_byte
{
   my $self = shift;
   my ( $fuse ) = @_;

   my $sii = $SII_FOR_FUSE_READ{$fuse} or croak "Unrecognised fuse type '$fuse'";

   $fuse eq "efuse" and !$self->{partinfo}->has_efuse and
      croak "This part does not have an 'efuse'";

   $self->_transfer( CMD_RFUSE, HVSP_CMD )
      ->then( sub { $self->_transfer( 0, $sii ) } )
      ->then( sub { $self->_transfer( 0, $sii|HVSP_ORM ) } )
}

=head2 $avr->write_fuse_byte( $fuse, $byte )->get

Writes one of the fuse bytes C<lfuse>, C<hfuse>, C<efuse> from an integer.

=cut

my %SII_FOR_FUSE_WRITE = (
   lfuse => HVSP_WFU0,
   hfuse => HVSP_WFU1,
   efuse => HVSP_WFU2,
);

sub write_fuse_byte
{
   my $self = shift;
   my ( $fuse, $byte ) = @_;

   my $sii = $SII_FOR_FUSE_WRITE{$fuse} or croak "Unrecognised fuse type '$fuse'";

   $fuse eq "efuse" and !$self->{part}->has_efuse and
      croak "This part does not have an 'efuse'";

   $self->_transfer( CMD_WFUSE, HVSP_CMD )
      ->then( sub { $self->_transfer( $byte, HVSP_LLB ) })
      ->then( sub { $self->_transfer( 0, $sii ) })
      ->then( sub { $self->_transfer( 0, $sii|HVSP_ORM ) })
      ->then( sub { $self->_await_SDO_high });
}

=head2 $byte = $avr->read_lfuse->get

=head2 $byte = $avr->read_hfuse->get

=head2 $byte = $avr->read_efuse->get

Convenient shortcuts to reading the low, high and extended fuses directly,
returning a byte.

=head2 $avr->write_lfuse( $byte )->get

=head2 $avr->write_hfuse( $byte )->get

=head2 $avr->write_efuse( $byte )->get

Convenient shortcuts for writing the low, high and extended fuses directly,
from a byte.

=cut

foreach my $fuse (qw( lfuse hfuse efuse )) {
   no strict 'refs';
   *{"read_$fuse"} = sub {
      shift->read_fuse_byte( $fuse )
         ->then( sub { Future->done( chr $_[0] ) });
   };
   *{"write_$fuse"} = sub {
      $_[0]->write_fuse_byte( $fuse, ord $_[1] );
   };
}

=head2 $bytes = $avr->read_flash( %args )->get

Reads a range of the flash memory and returns it as a binary string.

Takes the following optional arguments:

=over 4

=item start => INT

=item stop => INT

Address range to read. If omitted, reads the entire memory.

=item bytes => INT

Alternative to C<stop>; gives the nubmer of bytes (i.e. not words of flash)
to read.

=back

=cut

sub read_flash
{
   my $self = shift;
   my %opts = @_;

   my $partinfo = $self->{partinfo} or croak "Cannot ->read_flash of an unrecognised part";

   my $start = $opts{start} // 0;
   my $stop  = $opts{stop}  //
      $opts{bytes} ? $start + ( $opts{bytes}/2 ) : $partinfo->flash_words;

   my $bytes = "";

   $self->_transfer( CMD_RFLASH, HVSP_CMD )->then( sub {
      my $cur_ahi = -1;

      repeat {
         my ( $addr ) = @_;
         my $alo = $addr & 0xff;
         my $ahi = $addr >> 8;

         $self->_transfer( $alo, HVSP_LLA )
            ->then( sub { $cur_ahi == $ahi ? Future->done
                                           : $self->_transfer( $cur_ahi = $ahi, HVSP_LHA ) })
            ->then( sub { $self->_transfer( 0, HVSP_RLB ) })
            ->then( sub { $self->_transfer( 0, HVSP_RLB|HVSP_ORM ) })
            ->then( sub { $bytes .= chr $_[0];
                          $self->_transfer( 0, HVSP_RHB ) })
            ->then( sub { $self->_transfer( 0, HVSP_RHB|HVSP_ORM ) })
            ->then( sub { $bytes .= chr $_[0];
                          Future->done; });
      } foreach => [ $start .. $stop - 1 ],
        otherwise => sub { Future->done( $bytes ) };
   });
}

=head2 $avr->write_flash( $bytes )->get

Writes the flash memory from the binary string.

=cut

sub write_flash
{
   my $self = shift;
   my ( $bytes ) = @_;

   my $partinfo = $self->{partinfo} or croak "Cannot ->write_flash of an unrecognised part";
   my $nbytes_page = $partinfo->flash_pagesize * 2; # words are 2 bytes

   croak "Cannot write - too large" if length $bytes > $partinfo->flash_words * 2;

   $self->_transfer( CMD_WFLASH, HVSP_CMD )->then( sub {
      my @chunks = $bytes =~ m/(.{1,$nbytes_page})/gs;
      my $addr = 0;

      repeat {
         my $thisaddr = $addr;
         $addr += $partinfo->flash_pagesize;

         $self->_write_flash_page( $_[0], $thisaddr )
      } foreach => \@chunks;
   })
      ->then( sub { $self->_transfer( 0, HVSP_CMD ) });
}

sub _write_flash_page
{
   my $self = shift;
   my ( $bytes, $baseaddr ) = @_;

   (
      repeat {
         my $addr = $baseaddr + $_[0];
         my $byte_lo = substr $bytes, $_[0]*2, 1;
         my $byte_hi = substr $bytes, $_[0]*2 + 1, 1;

         # Datasheet disagrees with the byte value written in the final
         # instruction. Datasheet says 6C even though the OR mask would yield
         # the value 6E. It turns out emperically that either value works fine
         # so for neatness of following other code patterns, we use 6E here.

         $self->_transfer( $addr & 0xff, HVSP_LLA )
            ->then( sub { $self->_transfer( ord $byte_lo, HVSP_LLB ) })
            ->then( sub { $self->_transfer( 0, HVSP_PLL ) })
            ->then( sub { $self->_transfer( 0, HVSP_PLL|HVSP_ORM ) })
            ->then( sub { $self->_transfer( ord $byte_hi, HVSP_LHB ) })
            ->then( sub { $self->_transfer( 0, HVSP_PLH ) })
            ->then( sub { $self->_transfer( 0, HVSP_PLH|HVSP_ORM ) })
      } foreach => [ 0 .. length($bytes)/2 - 1 ]
   )
      ->then( sub { $self->_transfer( $baseaddr >> 8, HVSP_LHA ) })
      ->then( sub { $self->_transfer( 0, HVSP_WLB ) })
      ->then( sub { $self->_transfer( 0, HVSP_WLB|HVSP_ORM ) })
      ->then( sub { $self->_await_SDO_high });
}

=head2 $bytes = $avr->read_eeprom( %args )->get

Reads a range of the EEPROM memory and returns it as a binary string.

Takes the following optional arguments:

=over 4

=item start => INT

=item stop => INT

Address range to read. If omitted, reads the entire memory.

=item bytes => INT

Alternative to C<stop>; gives the nubmer of bytes to read.

=back

=cut

sub read_eeprom
{
   my $self = shift;
   my %opts = @_;

   my $partinfo = $self->{partinfo} or croak "Cannot ->read_eeprom of an unrecognised part";

   my $start = $opts{start} // 0;
   my $stop  = $opts{stop}  //
      $opts{bytes} ? $start + $opts{bytes} : $partinfo->eeprom_words;

   my $bytes = "";

   $self->_transfer( CMD_REEP, HVSP_CMD )->then( sub {
      my $cur_ahi = -1;

      repeat {
         my ( $addr ) = @_;
         my $alo = $addr & 0xff;
         my $ahi = $addr >> 8;

         $self->_transfer( $alo, HVSP_LLA )
            ->then( sub { $cur_ahi == $ahi ? Future->done
                                           : $self->_transfer( $cur_ahi = $ahi, HVSP_LHA ) } )
            ->then( sub { $self->_transfer( 0, HVSP_REEP ) } )
            ->then( sub { $self->_transfer( 0, HVSP_REEP|HVSP_ORM ) } )
            ->then( sub { $bytes .= chr $_[0];
                          Future->done; });
      } foreach => [ $start .. $stop - 1 ],
        otherwise => sub { Future->done( $bytes ) };
   });
}

=head2 $avr->write_eeprom( $bytes )->get

Writes the EEPROM memory from the binary string.

=cut

sub write_eeprom
{
   my $self = shift;
   my ( $bytes ) = @_;

   my $partinfo = $self->{partinfo} or croak "Cannot ->write_eeprom of an unrecognised part";

   croak "Cannot write - too large" if length $bytes > $partinfo->eeprom_words;

   my $nwords_page = $partinfo->eeprom_pagesize;

   $self->_transfer( CMD_WEEP, HVSP_CMD )->then( sub {
      my @chunks = $bytes =~ m/(.{1,$nwords_page})/gs;
      my $addr = 0;

      repeat {
         my $thisaddr = $addr;
         $addr += $nwords_page;

         $self->_write_eeprom_page( $_[0], $thisaddr )
      } foreach => \@chunks;
   })
      ->then( sub { $self->_transfer( 0, HVSP_CMD ) });
}

sub _write_eeprom_page
{
   my $self = shift;
   my ( $bytes, $baseaddr ) = @_;

   (
      repeat {
         my $addr = $baseaddr + $_[0];
         my $byte = substr $bytes, $_[0], 1;

         # Datasheet disagrees with the byte value written in the final
         # instruction. Datasheet says 6C even though the OR mask would yield
         # the value 6E. It turns out emperically that either value works fine
         # so for neatness of following other code patterns, we use 6E here.

         $self->_transfer( $addr & 0xff, HVSP_LLA )
            ->then( sub { $self->_transfer( $addr >> 8, HVSP_LHA ) })
            ->then( sub { $self->_transfer( ord $byte, HVSP_LLB ) })
            ->then( sub { $self->_transfer( 0, HVSP_PLL ) })
            ->then( sub { $self->_transfer( 0, HVSP_PLL|HVSP_ORM ) })
      } foreach => [ 0 .. length($bytes) - 1 ]
   )
      ->then( sub { $self->_transfer( 0, HVSP_WLB ) })
      ->then( sub { $self->_transfer( 0, HVSP_WLB|HVSP_ORM ) })
      ->then( sub { $self->_await_SDO_high });
}

=head1 SEE ALSO

=over 4

=item *

L<http://dangerousprototypes.com/2014/10/27/high-voltage-serial-programming-for-avr-chips-with-the-bus-pirate/> -
High voltage serial programming for AVR chips with the Bus Pirate.

=back

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
