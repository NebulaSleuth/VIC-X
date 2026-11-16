-- VIC-X: graphics and memory extension for the C64 (spec 0.1, draft)
--
-- Steps 1 and 2 of the FPGA block: the unlock, the ID and capability
-- registers, the two data ports with their auto-increment, VRAM, the
-- register space behind the ports, the palette, VIC-II colour remapping
-- (CTRL bit 3), the frame counter and the IRQ (step 1); bitmap layers
-- (step 2, CAP_FEAT bit 1); tile layers, layer 1 and the layer order
-- (step 3, CAP_FEAT bit 0); the DMA engine (step 5, CAP_FEAT bit 3).  The
-- sprite engine and the XRAM windows come later; their registers already
-- hold and read back their values.
--
-- Behaviour follows the VICE fork (src/vicx/vicx.c) register for register.
-- Plain VHDL-93 with inferred block RAM and no vendor IP, so the same file
-- builds in Quartus (MiSTer) and Vivado (Artix-7) and simulates in GHDL.
--
-- Bus interface
--   cpu_wr / cpu_rd are one-clock strobes, one per CPU access, with
--   cpu_addr / cpu_din valid in the same clock.  vic_cs qualifies them: the
--   access is to $D000-$D3FF with I/O mapped in; cpu_addr is the offset
--   within that range.  The VIC-II's own registers are not here: the core
--   keeps them, and leaves an access to VIC-X while `claim' is high.
--   cpu_dout is valid from the third clock after cpu_rd and held until the
--   next read, so the core must issue cpu_rd at least three clocks before it
--   samples the data.
--
-- Video interface
--   frame_start and line_start are one-clock strobes at raster line 0 and at
--   the start of each raster line; raster_y is the line number, valid with
--   line_start.  Each clock the block takes the VIC-II's colour index and the
--   core's RGB for it, and returns the RGB to show one clock later.
--   pix_ce marks the first clock of each pixel; with it come vic_bg (the
--   VIC-II drew this pixel from $D021: background, not foreground, sprite or
--   border) and vic_win (the pixel is in the 320x200 display window, lines
--   51-250, the area the border opens on with 40 columns and 25 rows).
--
-- Layers (vicx_layer.vhd)
--   CTRL, the layer setups and the layer order are latched at line_start.
--   Each layer fetches its line from then on, in 8-byte blocks, into a line
--   buffer that the display reads as it goes; the fetch starts about 16 C64
--   cycles before the window's left edge and runs faster than the display
--   uses it.  A pixel whose block has not arrived is drawn transparent and
--   pulses lay_late.  vic_border marks the VIC-II's border pixels, which
--   stay in front over the 320x200 area whatever the order says.
--
-- External VRAM (EXT_VRAM = true)
--   VRAM is not block RAM inside the block but a memory reached through the
--   vx_* port (on the MiSTer, the SDRAM controller's VIC-X port).  Hold vx_req
--   with vx_we / vx_addr / vx_din / vx_be until vx_ack; a read returns the
--   8-byte-aligned block holding vx_addr in vx_rdata (byte n in bits
--   8n+7..8n) when vx_rvalid is high.  Requests go one at a time.
--   The CPU takes port data three clocks after its read, far sooner than
--   external memory answers, so each port keeps a copy of the 8-byte block
--   it points at, fetched ahead whenever its address leaves that block.
--   Port writes go into a 16-entry queue and update any copy holding the
--   same byte; a fetch in flight when a write to its block arrives is
--   discarded and made again.  A read that finds no copy ready gets $FF and
--   pulses vx_miss: that needs reads closer together than any 6510 code
--   makes them, or a memory too slow for this block.
--
-- DMA engine (EXT_VRAM and CAP_FEAT bit 3)
--   Every space is reached through the vx_* port: C64 RAM at C64_BASE, VRAM
--   at VRAM_BASE, XRAM (the REU's memory, xram_mb MB) at XRAM_BASE.  The
--   engine works a byte at a time from an 8-byte read cache and writes words
--   (two bytes) at a time; VRAM writes go through the port write queue, so
--   the port copies stay right.  It takes the port after the CPU's writes,
--   the port fetches and the line fetch.  While a descriptor that touches C64
--   RAM runs, cpu_halt is high; the core holds the CPU the way the VIC-II's
--   BA does.
--
-- Reset
--   reset locks VIC-X, clears CTRL, IRQ, the ports and the layer setup, and restores the
--   stock palette.  The register space is then cleared by a sweep of about
--   2,500 clocks; VRAM keeps its contents (queued writes still go out).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package vicx_pkg is
    type rgb_array is array (0 to 15) of std_logic_vector(23 downto 0);
end package;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.vicx_pkg.all;

entity vicx is
    generic (
        VRAM_BITS    : natural := 17;           -- 2^17 = 128 KB
        CAP_SPR      : natural := 0;            -- what this build provides
        CAP_SPRLINE  : natural := 0;
        CAP_FEAT     : std_logic_vector(7 downto 0) := x"00";
        EXT_VRAM     : boolean := false;        -- VRAM through the vx_* port
        -- where the vx_* port finds each space (SDRAM byte addresses)
        VRAM_BASE    : natural := 16#0100000#;
        XRAM_BASE    : natural := 16#1000000#;
        C64_BASE     : natural := 16#0000000#
    );
    port (
        clk          : in  std_logic;
        reset        : in  std_logic;

        -- CPU bus
        vic_cs       : in  std_logic;
        cpu_addr     : in  std_logic_vector(9 downto 0);   -- offset in $D000-$D3FF
        cpu_din      : in  std_logic_vector(7 downto 0);
        cpu_wr       : in  std_logic;
        cpu_rd       : in  std_logic;
        claim        : out std_logic;                      -- VIC-X owns this access
        cpu_dout     : out std_logic_vector(7 downto 0);
        irq          : out std_logic;

        -- configuration from the core
        xram_mb      : in  std_logic_vector(7 downto 0);   -- REU size in MB, 0 = none
        stock_rgb    : in  rgb_array;                      -- the core's C64 palette

        -- video
        frame_start  : in  std_logic;
        line_start   : in  std_logic;
        vic_idx      : in  std_logic_vector(3 downto 0);
        vic_rgb      : in  std_logic_vector(23 downto 0);
        pix_ce       : in  std_logic := '1';               -- a new pixel this clock
        raster_y     : in  std_logic_vector(8 downto 0) := (others => '0');
        vic_bg       : in  std_logic := '0';               -- pixel drawn from $D021
        vic_win      : in  std_logic := '0';               -- pixel in the 320x200 window
        vic_border   : in  std_logic := '0';               -- pixel is the VIC-II's border
        rgb_out      : out std_logic_vector(23 downto 0);
        lay_late     : out std_logic;                      -- layer data not fetched in time

        -- external VRAM (EXT_VRAM only)
        vx_req       : out std_logic;
        vx_we        : out std_logic;
        vx_addr      : out std_logic_vector(24 downto 0);
        vx_din       : out std_logic_vector(15 downto 0);
        vx_be        : out std_logic_vector(1 downto 0);
        vx_ack       : in  std_logic := '0';
        vx_rdata     : in  std_logic_vector(63 downto 0) := (others => '0');
        vx_rvalid    : in  std_logic := '0';
        vx_miss      : out std_logic;
        cpu_halt     : out std_logic                       -- DMA touching C64 RAM: hold the CPU
    );
end entity;

architecture rtl of vicx is

    constant VERSION      : std_logic_vector(7 downto 0) := x"01";
    constant VRAM_SIZE    : natural := 2 ** VRAM_BITS;
    constant REGSPACE_SZ  : natural := 16#0A00#;           -- $20000-$209FF
    constant PAL_LO_SZ    : natural := 16#40#;             -- entries 0-15, in registers

    constant UNLOCK_REG   : natural := 16#6F#;

    type step_table_t is array (0 to 15) of natural range 0 to 640;
    constant STEP_TABLE : step_table_t :=
        (0, 1, 2, 4, 8, 16, 32, 40, 64, 80, 128, 160, 256, 320, 512, 640);

    type byte_array is array (natural range <>) of std_logic_vector(7 downto 0);
    type addr_array is array (0 to 1) of unsigned(17 downto 0);
    type step_array is array (0 to 1) of std_logic_vector(7 downto 0);

    -- lock state
    signal unlocked   : std_logic := '0';
    signal seq        : natural range 0 to 2 := 0;

    -- direct registers
    signal ctrl       : std_logic_vector(4 downto 0) := (others => '0');
    signal irq_en     : std_logic_vector(2 downto 0) := (others => '0');
    signal irq_stat   : std_logic_vector(2 downto 0) := (others => '0');
    signal frame      : unsigned(7 downto 0) := (others => '0');
    signal win        : byte_array(0 to 5) := (others => (others => '0'));
    signal port_addr  : addr_array := (others => (others => '0'));
    signal port_step  : step_array := (others => (others => '0'));

    -- palette entries 0-15 (R, G, B, spare each); until the first access
    -- after a reset they follow the core's stock palette
    signal pal_lo     : byte_array(0 to PAL_LO_SZ - 1) := (others => (others => '0'));
    signal pal_pend   : std_logic := '1';

    -- memories
    signal regs      : byte_array(0 to REGSPACE_SZ - 1);

    signal vram_q     : std_logic_vector(7 downto 0);
    signal regs_q     : std_logic_vector(7 downto 0);
    signal mem_raddr  : unsigned(17 downto 0) := (others => '0');

    signal vram_we    : std_logic := '0';
    signal regs_we    : std_logic := '0';
    signal mem_waddr  : unsigned(17 downto 0) := (others => '0');
    signal mem_wdata  : std_logic_vector(7 downto 0) := (others => '0');

    -- register-space clear after reset
    signal sweeping   : std_logic := '1';
    signal sweep_ptr  : unsigned(11 downto 0) := to_unsigned(PAL_LO_SZ, 12);

    -- read pipeline
    type rd_kind_t is (RD_NONE, RD_DIRECT, RD_PORT);
    type region_t is (REG_VRAM, REG_REGS, REG_PALLO, REG_ZERO, REG_UNMAPPED);
    signal rd_kind    : rd_kind_t := RD_NONE;
    signal rd_kind2   : rd_kind_t := RD_NONE;
    signal rd_val  : std_logic_vector(7 downto 0) := (others => '0');
    signal rd_val2 : std_logic_vector(7 downto 0) := (others => '0');
    signal rd_region  : region_t := REG_UNMAPPED;
    signal rd_region2 : region_t := REG_UNMAPPED;
    signal rd_pal     : std_logic_vector(7 downto 0) := (others => '0');
    signal rd_pal2    : std_logic_vector(7 downto 0) := (others => '0');
    signal dout       : std_logic_vector(7 downto 0) := (others => '1');

    -- external VRAM: each port's copy of its 8-byte block, the write queue
    -- and the request engine
    type blk_data_t is array (0 to 1) of std_logic_vector(63 downto 0);
    type blk_addr_t is array (0 to 1) of unsigned(13 downto 0);
    type wq_addr_t  is array (0 to 15) of unsigned(16 downto 0);
    type wq_data_t  is array (0 to 15) of std_logic_vector(15 downto 0);
    type wq_be_t    is array (0 to 15) of std_logic_vector(1 downto 0);
    type eng_t      is (E_IDLE, E_WREQ, E_DWREQ, E_RREQ, E_RWAIT);
    signal blk_data   : blk_data_t := (others => (others => '0'));
    signal blk_addr   : blk_addr_t := (others => (others => '0'));
    signal blk_valid  : std_logic_vector(1 downto 0) := "00";
    signal wq_addr    : wq_addr_t := (others => (others => '0'));
    signal wq_data    : wq_data_t := (others => (others => '0'));
    signal wq_be      : wq_be_t := (others => "00");
    signal wq_rd      : unsigned(3 downto 0) := (others => '0');
    signal wq_wr      : unsigned(3 downto 0) := (others => '0');
    signal wq_count   : natural range 0 to 16 := 0;
    signal eng        : eng_t := E_IDLE;
    signal f_blk      : unsigned(13 downto 0) := (others => '0');
    signal f_stale    : std_logic := '0';
    signal req_r      : std_logic := '0';
    signal we_r       : std_logic := '0';
    signal addr_r     : std_logic_vector(24 downto 0) := (others => '0');
    signal din_r      : std_logic_vector(15 downto 0) := (others => '0');
    signal be_r       : std_logic_vector(1 downto 0) := "00";
    signal miss_r     : std_logic := '0';
    signal rd_ext     : std_logic_vector(7 downto 0) := (others => '0');
    signal rd_ext2    : std_logic_vector(7 downto 0) := (others => '0');

    -- the port's block is in its copy
    function has_blk(bv : std_logic_vector(1 downto 0); ba : blk_addr_t;
                     q : natural; a : unsigned(17 downto 0)) return boolean is
    begin
        return bv(q) = '1' and ba(q) = a(16 downto 3);
    end function;

    -- DMA engine
    constant HAS_DMA  : boolean := EXT_VRAM and CAP_FEAT(3) = '1';
    type d8_t  is array (0 to 3) of std_logic_vector(7 downto 0);
    type d16_t is array (0 to 3) of unsigned(15 downto 0);
    type d24_t is array (0 to 3) of unsigned(23 downto 0);
    -- the four descriptors at $20880, as written (the fields the engine uses)
    signal dsc_op, dsc_sp, dsc_fill, dsc_tr, dsc_next : d8_t := (others => (others => '0'));
    signal dsc_src, dsc_dst : d24_t := (others => (others => '0'));
    signal dsc_w, dsc_h, dsc_ss, dsc_ds : d16_t := (others => (others => '0'));
    type dmst_t is (DM_IDLE, DM_START, DM_BYTE, DM_RWAIT, DM_RRD, DM_RR1, DM_RR2,
                  DM_PUT, DM_FLUSH, DM_WWAIT, DM_NEXT);
    signal dm_st      : dmst_t := DM_IDLE;
    signal dm_ret     : dmst_t := DM_IDLE;          -- where a flush goes back to
    signal dm_busy    : std_logic := '0';
    signal dm_c64     : std_logic := '0';
    signal dm_n       : natural range 0 to 3 := 0;
    signal dm_ran     : std_logic_vector(3 downto 0) := (others => '0');
    signal dm_irqp    : std_logic := '0';
    signal dm_op      : std_logic_vector(1 downto 0) := "00";
    signal dm_ss      : std_logic_vector(1 downto 0) := "00";
    signal dm_ds      : std_logic_vector(1 downto 0) := "00";
    signal dm_fill    : std_logic_vector(7 downto 0) := (others => '0');
    signal dm_tr      : std_logic_vector(7 downto 0) := (others => '0');
    signal dm_s, dm_t, dm_srow, dm_trow : unsigned(23 downto 0) := (others => '0');
    signal dm_sst, dm_dst : unsigned(15 downto 0) := (others => '0');
    signal dm_w, dm_i, dm_h, dm_r : unsigned(15 downto 0) := (others => '0');
    signal dm_cvalid  : std_logic := '0';         -- read cache: 8 bytes at dm_ckey
    signal dm_ckey    : unsigned(21 downto 0) := (others => '0');
    signal dm_cdata   : std_logic_vector(63 downto 0) := (others => '0');
    signal dm_wa      : unsigned(24 downto 0) := (others => '0');   -- write buffer
    signal dm_wd      : std_logic_vector(15 downto 0) := (others => '0');
    signal dm_wbe     : std_logic_vector(1 downto 0) := "00";
    signal dm_wvram   : std_logic := '0';         -- the buffer is for VRAM
    signal dm_val     : std_logic_vector(7 downto 0) := (others => '0');
    signal dmr_req    : std_logic := '0';         -- request to the engine
    signal dmr_we     : std_logic := '0';
    signal dmr_addr   : unsigned(24 downto 0) := (others => '0');
    signal f_dma      : std_logic := '0';         -- the read in flight is the DMA's
    signal xmask      : unsigned(23 downto 0);

    -- video
    constant HAS_BMP  : boolean := CAP_FEAT(1) = '1';
    constant WIN_TOP  : natural := 51;
    signal line_ctrl  : std_logic_vector(4 downto 0) := (others => '0');
    signal rgb_q      : std_logic_vector(23 downto 0) := (others => '0');

    -- layer setups as last written ($20800 and $20820, bytes 0-14), and
    -- the layer order ($20840)
    type lset_t is array (0 to 1) of std_logic_vector(119 downto 0);
    signal l_set      : lset_t := (others => (others => '0'));
    signal s_order    : std_logic_vector(7 downto 0) := (others => '0');
    constant HAS_TILES : boolean := CAP_FEAT(0) = '1';

    -- this line: who is in front of whom
    signal ord_l0_l1  : std_logic := '1';          -- layer 0 in front of layer 1
    signal ord_vic_l0 : std_logic := '1';          -- VIC-II in front of layer 0
    signal ord_vic_l1 : std_logic := '1';

    -- the layers and their fetches
    type uaddr_t is array (0 to 1) of unsigned(13 downto 0);
    type uidx_t  is array (0 to 1) of std_logic_vector(7 downto 0);
    signal u_req      : std_logic_vector(1 downto 0);
    signal u_addr     : uaddr_t;
    signal u_gnt      : std_logic_vector(1 downto 0) := "00";
    signal u_valid    : std_logic_vector(1 downto 0) := "00";
    signal u_data     : std_logic_vector(63 downto 0) := (others => '0');
    signal u_pref     : std_logic := '0';          -- whose turn when both ask
    signal f_line     : std_logic := '0';          -- the read in flight is a layer's
    signal f_lu       : natural range 0 to 1 := 0;
    signal q_idx      : uidx_t;
    signal q_ok       : std_logic_vector(1 downto 0);
    signal q_late     : std_logic_vector(1 downto 0);
    signal win_y      : unsigned(8 downto 0);
    signal in_win     : std_logic;

    -- block RAM VRAM: a layer's block read a byte at a time, on clocks the
    -- CPU leaves the read port free
    signal br_busy    : std_logic := '0';
    signal br_u       : natural range 0 to 1 := 0;
    signal br_blk     : unsigned(13 downto 0) := (others => '0');
    signal br_n       : natural range 0 to 8 := 0;
    signal br_i       : unsigned(2 downto 0) := (others => '0');
    signal br_iss     : std_logic := '0';
    signal br_ib      : unsigned(2 downto 0) := (others => '0');
    signal br_buf     : std_logic_vector(63 downto 0) := (others => '0');
    signal br_addr    : unsigned(16 downto 0);
    signal vram_ra    : unsigned(16 downto 0);

    -- palette entries 16-255 for the display (copies of the register space)
    type pal_ram_t is array (0 to 255) of std_logic_vector(7 downto 0);
    signal pal_r, pal_g, pal_b : pal_ram_t := (others => (others => '0'));
    signal pal_ra     : unsigned(7 downto 0);
    signal pal_q      : std_logic_vector(23 downto 0) := (others => '0');

    -- display: the frontmost opaque layer for each pixel, then its colour
    signal vx_x       : unsigned(8 downto 0) := (others => '0');   -- window pixel
    signal w_idx      : std_logic_vector(7 downto 0);
    signal w_ok       : std_logic;
    signal w_vf       : std_logic;                 -- the VIC-II is in front of it
    signal b_idx      : std_logic_vector(7 downto 0) := (others => '0');
    signal b_ok       : std_logic := '0';
    signal b_vf       : std_logic := '0';
    signal b_late     : std_logic := '0';
    signal cur_ok     : std_logic := '0';
    signal cur_vf     : std_logic := '0';
    signal cur_rgb    : std_logic_vector(23 downto 0) := (others => '0');
    signal late_r     : std_logic := '0';

    function in_regs(off : natural) return boolean is
    begin
        return off >= 16#40# and off <= 16#6F#;
    end function;

    -- which memory a port address reaches
    function region_of(a : unsigned(17 downto 0)) return region_t is
    begin
        if to_integer(a) < VRAM_SIZE then
            return REG_VRAM;
        elsif a(17) = '1' and to_integer(a(16 downto 0)) < REGSPACE_SZ then
            if to_integer(a(16 downto 0)) < PAL_LO_SZ then
                return REG_PALLO;
            end if;
            return REG_REGS;
        end if;
        return REG_UNMAPPED;
    end function;

    function stepped(a : unsigned(17 downto 0); s : std_logic_vector(7 downto 0))
        return unsigned is
        variable d : unsigned(17 downto 0);
    begin
        d := to_unsigned(STEP_TABLE(to_integer(unsigned(s(6 downto 3)))), 18);
        if s(7) = '1' then
            return a - d;
        end if;
        return a + d;
    end function;

    function stock_byte(p : rgb_array; i : natural) return std_logic_vector is
        variable c : std_logic_vector(23 downto 0);
    begin
        c := p(i / 4);
        case i mod 4 is
            when 0      => return c(23 downto 16);
            when 1      => return c(15 downto 8);
            when 2      => return c(7 downto 0);
            when others => return x"00";
        end case;
    end function;

    function pal_rgb(p : byte_array; i : natural) return std_logic_vector is
    begin
        return p(i * 4) & p(i * 4 + 1) & p(i * 4 + 2);
    end function;

    function byte_of(d : std_logic_vector(63 downto 0); n : unsigned(2 downto 0))
        return std_logic_vector is
        variable i : natural range 0 to 7;
    begin
        i := to_integer(n);
        return d(8 * i + 7 downto 8 * i);
    end function;

begin

    -- VIC-X owns $D040-$D06F while unlocked; the mirrors at $D100-$D3FF never
    claim <= '1' when vic_cs = '1' and unlocked = '1' and cpu_addr(9 downto 8) = "00"
                      and in_regs(to_integer(unsigned(cpu_addr(7 downto 0))))
             else '0';

    irq      <= '1' when (irq_stat and irq_en) /= "000" else '0';
    cpu_dout <= dout;
    rgb_out  <= rgb_q;

    vx_req   <= req_r;
    vx_we    <= we_r;
    vx_addr  <= addr_r;
    vx_din   <= din_r;
    vx_be    <= be_r;
    vx_miss  <= miss_r;
    lay_late <= late_r;
    cpu_halt <= dm_c64;

    -- XRAM wraps at its size (a power of two MB; 16 MB and up: 24 bits)
    xmask <= (others => '1') when unsigned(xram_mb) >= 16 else
             shift_left(resize(unsigned(xram_mb), 24), 20) - 1;

    ---------------------------------------------------------------------------
    -- memories: one read port and one write port each

    gen_bram : if not EXT_VRAM generate
        signal vram : byte_array(0 to VRAM_SIZE - 1);
    begin
        vram_mem : process (clk)
        begin
            if rising_edge(clk) then
                if vram_we = '1' then
                    vram(to_integer(mem_waddr(VRAM_BITS - 1 downto 0))) <= mem_wdata;
                end if;
                vram_q <= vram(to_integer(vram_ra(VRAM_BITS - 1 downto 0)));
            end if;
        end process;
    end generate;

    gen_ext : if EXT_VRAM generate
        vram_q <= x"FF";
    end generate;

    -- the block RAM's read port: a CPU port read in its clock, else the
    -- line fetch
    vram_ra <= mem_raddr(16 downto 0) when rd_kind = RD_PORT else br_addr;
    br_addr <= br_blk & br_i;

    -- the two layers
    win_y  <= unsigned(raster_y) - WIN_TOP;
    in_win <= '1' when unsigned(raster_y) >= WIN_TOP and unsigned(raster_y) < WIN_TOP + 200 else '0';

    gen_layers : for n in 0 to 1 generate
        lay : entity work.vicx_layer
            generic map (HAS_TILES => HAS_TILES, HAS_BMP => HAS_BMP)
            port map (
                clk => clk, reset => reset,
                line_start => line_start, enable => ctrl(n),
                win_y => win_y, in_win => in_win, setup => l_set(n),
                f_req => u_req(n), f_addr => u_addr(n), f_gnt => u_gnt(n),
                f_valid => u_valid(n), f_data => u_data,
                x => vx_x, q_idx => q_idx(n), q_ok => q_ok(n), q_late => q_late(n));
    end generate;

    -- the frontmost opaque layer (the VIC-II's place in the order is
    -- settled per pixel in the video process)
    w_idx <= q_idx(0) when q_ok(0) = '1' and (q_ok(1) = '0' or ord_l0_l1 = '1') else
             q_idx(1) when q_ok(1) = '1' else x"00";
    w_ok  <= q_ok(0) or q_ok(1);
    w_vf  <= ord_vic_l0 when q_ok(0) = '1' and (q_ok(1) = '0' or ord_l0_l1 = '1') else ord_vic_l1;

    -- palette entries 16-255 for the display: follow every write to them
    -- in the register space, and the clear after reset
    pal_mem : process (clk)
        variable wa : unsigned(11 downto 0);
        variable wd : std_logic_vector(7 downto 0);
    begin
        if rising_edge(clk) then
            if sweeping = '1' then
                wa := sweep_ptr;
                wd := x"00";
            else
                wa := mem_waddr(11 downto 0);
                wd := mem_wdata;
            end if;
            if (regs_we = '1' or sweeping = '1') and wa(11 downto 10) = "00" then
                case wa(1 downto 0) is
                    when "00"   => pal_r(to_integer(wa(9 downto 2))) <= wd;
                    when "01"   => pal_g(to_integer(wa(9 downto 2))) <= wd;
                    when "10"   => pal_b(to_integer(wa(9 downto 2))) <= wd;
                    when others => null;
                end case;
            end if;
            pal_q <= pal_r(to_integer(pal_ra)) & pal_g(to_integer(pal_ra)) &
                     pal_b(to_integer(pal_ra));
        end if;
    end process;

    pal_ra <= unsigned(w_idx);

    regs_mem : process (clk)
        variable wa : natural range 0 to 4095;
    begin
        if rising_edge(clk) then
            if sweeping = '1' then
                wa := to_integer(sweep_ptr);
            else
                wa := to_integer(mem_waddr(11 downto 0));
            end if;
            if (regs_we = '1' or sweeping = '1') and wa < REGSPACE_SZ then
                if sweeping = '1' then
                    regs(wa) <= x"00";
                else
                    regs(wa) <= mem_wdata;
                end if;
            end if;
            if to_integer(mem_raddr(11 downto 0)) < REGSPACE_SZ then
                regs_q <= regs(to_integer(mem_raddr(11 downto 0)));
            else
                regs_q <= x"FF";
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- registers, unlock and ports

    main : process (clk)
        variable off     : natural range 0 to 255;
        variable p       : natural range 0 to 1;
        variable a       : unsigned(17 downto 0);
        variable rgn     : region_t;
        variable pi      : natural range 0 to PAL_LO_SZ - 1;
        variable pal_v   : byte_array(0 to PAL_LO_SZ - 1);
        variable pend_v  : std_logic;
        variable v       : std_logic_vector(7 downto 0);
        variable bd      : blk_data_t;
        variable bv      : std_logic_vector(1 downto 0);
        variable ba      : blk_addr_t;
        variable stale_v : std_logic;
        variable wqc     : natural range 0 to 16;
        variable wqw     : unsigned(3 downto 0);
        variable bi      : natural range 0 to 7;
        variable bdv     : natural range 0 to 41;
        variable issued  : boolean;
        variable yi      : integer range -512 to 511;
        variable row     : unsigned(18 downto 0);
        variable nb      : natural range 0 to 320;
        variable bb      : std_logic_vector(63 downto 0);
        variable dmok    : boolean;                -- the engine finished the DMA's request
        variable dval    : std_logic_vector(7 downto 0);
        variable dput    : boolean;
        variable sdst    : unsigned(24 downto 0);  -- SDRAM address of the destination
        variable ssrc    : unsigned(24 downto 0);
        variable dkind   : natural range 0 to 3;   -- 0 nothing, 1 SDRAM, 2 regs, 3 low palette
        variable skind   : natural range 0 to 3;
        variable lane    : natural range 0 to 1;
        variable wb      : std_logic_vector(15 downto 0);
        variable wbe     : std_logic_vector(1 downto 0);
        variable wbv     : std_logic_vector(7 downto 0);
        variable dn      : natural range 0 to 3;

        -- a store to the register space (CPU port or DMA): what the display
        -- and the DMA engine keep copies of
        procedure regs_snoop(ra : unsigned(11 downto 0); d : std_logic_vector(7 downto 0)) is
            variable q : natural range 0 to 3;
        begin
            if ra(11 downto 6) = "100000" then          -- layer setups
                q := to_integer(ra(5 downto 5));
                for b in 0 to 14 loop
                    if to_integer(ra(4 downto 0)) = b then
                        l_set(q)(8 * b + 7 downto 8 * b) <= d;
                    end if;
                end loop;
            end if;
            if ra = x"840" then                          -- layer order
                s_order <= d;
            end if;
            if ra(11 downto 7) = "10001" then           -- DMA descriptors
                q := to_integer(ra(6 downto 5));
                case to_integer(ra(4 downto 0)) is
                    when 0  => dsc_op(q) <= d;
                    when 1  => dsc_sp(q) <= d;
                    when 2  => dsc_src(q)(7 downto 0)   <= unsigned(d);
                    when 3  => dsc_src(q)(15 downto 8)  <= unsigned(d);
                    when 4  => dsc_src(q)(23 downto 16) <= unsigned(d);
                    when 6  => dsc_dst(q)(7 downto 0)   <= unsigned(d);
                    when 7  => dsc_dst(q)(15 downto 8)  <= unsigned(d);
                    when 8  => dsc_dst(q)(23 downto 16) <= unsigned(d);
                    when 10 => dsc_w(q)(7 downto 0)   <= unsigned(d);
                    when 11 => dsc_w(q)(15 downto 8)  <= unsigned(d);
                    when 12 => dsc_h(q)(7 downto 0)   <= unsigned(d);
                    when 13 => dsc_h(q)(15 downto 8)  <= unsigned(d);
                    when 14 => dsc_ss(q)(7 downto 0)  <= unsigned(d);
                    when 15 => dsc_ss(q)(15 downto 8) <= unsigned(d);
                    when 16 => dsc_ds(q)(7 downto 0)  <= unsigned(d);
                    when 17 => dsc_ds(q)(15 downto 8) <= unsigned(d);
                    when 18 => dsc_fill(q) <= d;
                    when 19 => dsc_tr(q)   <= d;
                    when 20 => dsc_next(q) <= d;
                    when others => null;
                end case;
            end if;
        end procedure;

        -- where a DMA address in a space goes: kind and SDRAM address
        procedure dm_map(sp : std_logic_vector(1 downto 0); da : unsigned(23 downto 0);
                         kind : out natural; sa : out unsigned(24 downto 0)) is
        begin
            sa := (others => '0');
            kind := 0;
            case sp is
                when "00" =>                            -- C64 RAM
                    kind := 1;
                    sa := to_unsigned(C64_BASE, 25) + resize(da(15 downto 0), 25);
                when "01" =>                            -- VRAM and the register space
                    if da(17) = '0' then
                        if to_integer(da(16 downto 0)) < VRAM_SIZE then
                            kind := 1;
                            sa := to_unsigned(VRAM_BASE, 25) + resize(da(16 downto 0), 25);
                        end if;
                    elsif to_integer(da(16 downto 0)) < PAL_LO_SZ then
                        kind := 3;
                    elsif to_integer(da(16 downto 0)) < REGSPACE_SZ then
                        kind := 2;
                    end if;
                when "10" =>                            -- XRAM
                    if unsigned(xram_mb) /= 0 then
                        kind := 1;
                        sa := to_unsigned(XRAM_BASE, 25) + resize(da and xmask, 25);
                    end if;
                when others => null;
            end case;
        end procedure;
    begin
        if rising_edge(clk) then
            vram_we <= '0';
            regs_we <= '0';
            rd_kind <= RD_NONE;
            miss_r  <= '0';
            u_gnt   <= "00";
            u_valid <= "00";
            dmok    := false;

            bd := blk_data;
            bv := blk_valid;
            ba := blk_addr;
            stale_v := f_stale;
            wqc := wq_count;
            wqw := wq_wr;

            -- external VRAM engine: finish the request in hand first, so the
            -- CPU access below sees a block that arrives in this clock
            if EXT_VRAM then
                case eng is
                    when E_WREQ =>
                        if vx_ack = '1' then
                            req_r <= '0';
                            wq_rd <= wq_rd + 1;
                            wqc := wqc - 1;
                            eng <= E_IDLE;
                        end if;
                    when E_DWREQ =>
                        if vx_ack = '1' then
                            req_r <= '0';
                            dmok := true;
                            eng <= E_IDLE;
                        end if;
                    when E_RREQ =>
                        if vx_ack = '1' then
                            req_r <= '0';
                            eng <= E_RWAIT;
                        end if;
                    when E_RWAIT =>
                        if vx_rvalid = '1' and f_dma = '1' then
                            dmok := true;
                            eng <= E_IDLE;
                        elsif vx_rvalid = '1' and f_line = '1' then
                            -- a layer's block
                            u_valid(f_lu) <= '1';
                            u_data <= vx_rdata;
                            eng <= E_IDLE;
                        elsif vx_rvalid = '1' then
                            if stale_v = '0' then
                                for q in 0 to 1 loop
                                    if region_of(port_addr(q)) = REG_VRAM and
                                       port_addr(q)(16 downto 3) = f_blk then
                                        bd(q) := vx_rdata;
                                        bv(q) := '1';
                                        ba(q) := f_blk;
                                    end if;
                                end loop;
                            end if;
                            eng <= E_IDLE;
                        end if;
                    when E_IDLE =>
                        null;
                end case;
            end if;

            -- block RAM VRAM: a layer's block, a byte at a time, on clocks the
            -- CPU leaves the read port free (see vram_ra)
            if not EXT_VRAM then
                if br_iss = '1' then
                    bb := br_buf;
                    bb(8 * to_integer(br_ib) + 7 downto 8 * to_integer(br_ib)) := vram_q;
                    br_buf <= bb;
                    if br_ib = "111" then
                        u_valid(br_u) <= '1';
                        u_data  <= bb;
                        br_busy <= '0';
                    end if;
                end if;
                br_iss <= '0';
                if br_busy = '1' then
                    if br_n < 8 and rd_kind /= RD_PORT then
                        br_iss <= '1';
                        br_ib  <= br_i;
                        br_i   <= br_i + 1;
                        br_n   <= br_n + 1;
                    end if;
                elsif line_start = '0' and u_req /= "00" and u_gnt = "00" then
                    if u_req(0) = '1' and (u_req(1) = '0' or u_pref = '0') then
                        dn := 0;
                    else
                        dn := 1;
                    end if;
                    u_pref     <= not u_pref;
                    u_gnt(dn)  <= '1';
                    br_u       <= dn;
                    br_blk     <= u_addr(dn);
                    br_busy    <= '1';
                    br_n       <= 0;
                    br_i       <= (others => '0');
                end if;
            end if;

            -- register-space sweep
            if sweeping = '1' then
                if to_integer(sweep_ptr) = REGSPACE_SZ - 1 then
                    sweeping <= '0';
                end if;
                sweep_ptr <= sweep_ptr + 1;
            end if;

            -- frame and line events
            if frame_start = '1' then
                frame <= frame + 1;
                irq_stat(2) <= '1';
            end if;

            pal_v  := pal_lo;
            pend_v := pal_pend;

            if vic_cs = '1' and cpu_wr = '1' then
                if cpu_addr(9 downto 8) /= "00" then
                    seq <= 0;                           -- a mirror: cancels a partial unlock
                else
                    off := to_integer(unsigned(cpu_addr(7 downto 0)));
                    if off = UNLOCK_REG then
                        if cpu_din = x"00" then
                            unlocked <= '0';
                            seq <= 0;
                        elsif (seq = 0 and cpu_din = x"56") or
                              (seq = 1 and cpu_din = x"58") then
                            seq <= seq + 1;
                        elsif seq = 2 and cpu_din = x"21" then
                            unlocked <= '1';
                            seq <= 0;
                        elsif cpu_din = x"56" then
                            seq <= 1;                   -- a repeated $56 restarts
                        else
                            seq <= 0;
                        end if;
                    else
                        seq <= 0;
                        if unlocked = '1' and in_regs(off) then
                            case off is
                                when 16#48# => ctrl   <= cpu_din(4 downto 0);
                                when 16#49# => irq_en <= cpu_din(2 downto 0);
                                when 16#4A# => irq_stat <= irq_stat and not cpu_din(2 downto 0);
                                when 16#4C# | 16#4D# | 16#4E# | 16#50# | 16#51# | 16#52# =>
                                    if off < 16#50# then p := 0; else p := 1; end if;
                                    case off mod 4 is
                                        when 0 => port_addr(p)(7 downto 0)  <= unsigned(cpu_din);
                                        when 1 => port_addr(p)(15 downto 8) <= unsigned(cpu_din);
                                        when others =>
                                            port_addr(p)(17 downto 16) <= unsigned(cpu_din(1 downto 0));
                                            port_step(p) <= cpu_din(7 downto 3) & "000";
                                    end case;
                                when 16#4F# | 16#53# =>
                                    if off = 16#4F# then p := 0; else p := 1; end if;
                                    a := port_addr(p);
                                    rgn := region_of(a);
                                    case rgn is
                                        when REG_VRAM =>
                                            if EXT_VRAM then
                                                -- queue it, and update the copies
                                                if wqc < 16 then
                                                    wq_addr(to_integer(wqw)) <= a(16 downto 0);
                                                    wq_data(to_integer(wqw)) <= cpu_din & cpu_din;
                                                    if a(0) = '1' then
                                                        wq_be(to_integer(wqw)) <= "10";
                                                    else
                                                        wq_be(to_integer(wqw)) <= "01";
                                                    end if;
                                                    wqw := wqw + 1;
                                                    wqc := wqc + 1;
                                                end if;
                                                bi := to_integer(a(2 downto 0));
                                                for q in 0 to 1 loop
                                                    if has_blk(bv, ba, q, a) then
                                                        bd(q)(8 * bi + 7 downto 8 * bi) := cpu_din;
                                                    end if;
                                                end loop;
                                                if (eng = E_RREQ or eng = E_RWAIT) and
                                                   f_blk = a(16 downto 3) then
                                                    stale_v := '1';
                                                end if;
                                            else
                                                vram_we <= '1';
                                            end if;
                                        when REG_PALLO =>
                                            if pend_v = '1' then
                                                for i in 0 to PAL_LO_SZ - 1 loop
                                                    pal_v(i) := stock_byte(stock_rgb, i);
                                                end loop;
                                                pend_v := '0';
                                            end if;
                                            pi := to_integer(a(5 downto 0));
                                            pal_v(pi) := cpu_din;
                                        when REG_REGS =>
                                            -- during the sweep, a write the sweep has not reached
                                            -- yet would be cleared again: drop it
                                            if sweeping = '0' or a(11 downto 0) < sweep_ptr then
                                                regs_we <= '1';
                                                regs_snoop(a(11 downto 0), cpu_din);
                                            end if;
                                        when others =>
                                            null;               -- unmapped: ignored
                                    end case;
                                    mem_waddr <= a;
                                    mem_wdata <= cpu_din;
                                    port_addr(p) <= stepped(a, port_step(p));
                                when 16#54# | 16#57# => win(off - 16#54#) <= cpu_din;
                                when 16#55# | 16#58# => win(off - 16#54#) <= "00000" & cpu_din(2 downto 0);
                                when 16#56# | 16#59# => win(off - 16#54#) <= cpu_din(7) & "0000" & cpu_din(2 downto 0);
                                when 16#5A# =>
                                    -- DMA_CMD: start a chain; ignored while busy
                                    if HAS_DMA and dm_busy = '0' then
                                        dm_busy <= '1';
                                        dm_n    <= to_integer(unsigned(cpu_din(1 downto 0)));
                                        dm_ran  <= (others => '0');
                                        dm_irqp <= '0';
                                        dm_st   <= DM_START;
                                    end if;
                                when others => null;    -- read-only, reserved
                            end case;
                        end if;
                    end if;
                end if;
            end if;

            -- reads: decode now, data out two clocks later
            if vic_cs = '1' and cpu_rd = '1' and unlocked = '1' and cpu_addr(9 downto 8) = "00"
               and in_regs(to_integer(unsigned(cpu_addr(7 downto 0)))) then
                off := to_integer(unsigned(cpu_addr(7 downto 0)));
                rd_kind <= RD_DIRECT;
                v := x"FF";
                case off is
                    when 16#40# => v := x"56";
                    when 16#41# => v := x"58";
                    when 16#42# => v := VERSION;
                    when 16#43# => v := std_logic_vector(to_unsigned(VRAM_SIZE / 8192, 8));
                    when 16#44# => v := xram_mb;
                    when 16#45# => v := std_logic_vector(to_unsigned(CAP_SPR, 8));
                    when 16#46# => v := std_logic_vector(to_unsigned(CAP_SPRLINE, 8));
                    when 16#47# => v := CAP_FEAT;
                    when 16#48# => v := "000" & ctrl;
                    when 16#49# => v := "00000" & irq_en;
                    when 16#4A# => v := "00000" & irq_stat;
                    when 16#4B# => v := std_logic_vector(frame);
                    when 16#4C# | 16#4D# | 16#4E# | 16#50# | 16#51# | 16#52# =>
                        if off < 16#50# then p := 0; else p := 1; end if;
                        case off mod 4 is
                            when 0 => v := std_logic_vector(port_addr(p)(7 downto 0));
                            when 1 => v := std_logic_vector(port_addr(p)(15 downto 8));
                            when others =>
                                v := port_step(p)(7 downto 3) & "0" &
                                     std_logic_vector(port_addr(p)(17 downto 16));
                        end case;
                    when 16#4F# | 16#53# =>
                        if off = 16#4F# then p := 0; else p := 1; end if;
                        a := port_addr(p);
                        rgn := region_of(a);
                        if rgn = REG_PALLO and pend_v = '1' then
                            for i in 0 to PAL_LO_SZ - 1 loop
                                pal_v(i) := stock_byte(stock_rgb, i);
                            end loop;
                            pend_v := '0';
                        end if;
                        if rgn = REG_REGS and sweeping = '1' and a(11 downto 0) >= sweep_ptr then
                            rgn := REG_ZERO;            -- not swept yet: reads as cleared
                        end if;
                        rd_kind   <= RD_PORT;
                        rd_region <= rgn;
                        rd_pal    <= pal_v(to_integer(a(5 downto 0)));
                        if EXT_VRAM and rgn = REG_VRAM then
                            bi := to_integer(a(2 downto 0));
                            if has_blk(bv, ba, p, a) then
                                rd_ext <= bd(p)(8 * bi + 7 downto 8 * bi);
                            else
                                rd_ext <= x"FF";
                                miss_r <= '1';
                            end if;
                        end if;
                        mem_raddr <= a;
                        port_addr(p) <= stepped(a, port_step(p));
                    when 16#54# to 16#59# => v := win(off - 16#54#);
                    when 16#5A# => v := dm_busy & "0000000";   -- DMA_CMD: bit 7 busy
                    when others => v := x"FF";          -- reserved, and $D06F
                end case;
                rd_val <= v;
            end if;

            -- DMA engine: one step per clock
            if HAS_DMA then
                dput := false;
                dval := x"FF";
                case dm_st is
                    when DM_IDLE =>
                        null;

                    when DM_START =>
                        dn := dm_n;
                        dm_ran(dn) <= '1';
                        if dsc_sp(dn)(5) = '1' then
                            dm_irqp <= '1';
                        end if;
                        dm_op   <= dsc_op(dn)(1 downto 0);
                        dm_ss   <= dsc_sp(dn)(1 downto 0);
                        dm_ds   <= dsc_sp(dn)(3 downto 2);
                        dm_fill <= dsc_fill(dn);
                        dm_tr   <= dsc_tr(dn);
                        dm_s    <= dsc_src(dn);
                        dm_srow <= dsc_src(dn);
                        dm_t    <= dsc_dst(dn);
                        dm_trow <= dsc_dst(dn);
                        dm_w    <= dsc_w(dn);
                        dm_sst  <= dsc_ss(dn);
                        dm_dst  <= dsc_ds(dn);
                        dm_i    <= (others => '0');
                        dm_r    <= (others => '0');
                        if dsc_sp(dn)(4) = '1' then
                            dm_h <= dsc_h(dn);
                        else
                            dm_h <= to_unsigned(1, 16);
                        end if;
                        dm_cvalid <= '0';
                        -- reserved operations and spaces, and empty transfers, do nothing
                        if unsigned(dsc_op(dn)) > 2 or dsc_sp(dn)(3 downto 2) = "11" or
                           (dsc_op(dn) /= x"01" and dsc_sp(dn)(1 downto 0) = "11") or
                           dsc_w(dn) = 0 or (dsc_sp(dn)(4) = '1' and dsc_h(dn) = 0) then
                            dm_st <= DM_NEXT;
                        else
                            if dsc_sp(dn)(3 downto 2) = "00" or
                               (dsc_op(dn) /= x"01" and dsc_sp(dn)(1 downto 0) = "00") then
                                dm_c64 <= '1';
                            end if;
                            dm_st <= DM_BYTE;
                        end if;

                    when DM_BYTE =>
                        if dm_i = dm_w then
                            -- end of a row
                            if dm_r + 1 >= dm_h then
                                if dm_wbe /= "00" then
                                    dm_ret <= DM_NEXT;
                                    dm_st  <= DM_FLUSH;
                                else
                                    dm_st  <= DM_NEXT;
                                end if;
                            else
                                dm_r    <= dm_r + 1;
                                dm_i    <= (others => '0');
                                dm_srow <= dm_srow + resize(dm_sst, 24);
                                dm_trow <= dm_trow + resize(dm_dst, 24);
                                dm_s    <= dm_srow + resize(dm_sst, 24);
                                dm_t    <= dm_trow + resize(dm_dst, 24);
                            end if;
                        else
                            dm_map(dm_ds, dm_t, dkind, sdst);
                            dm_map(dm_ss, dm_s, skind, ssrc);
                            if dm_wbe /= "00" and
                               (dkind /= 1 or dm_wa(24 downto 1) /= sdst(24 downto 1)) then
                                -- the buffered word first
                                dm_ret <= DM_BYTE;
                                dm_st  <= DM_FLUSH;
                            elsif dm_op = "01" then
                                dval := dm_fill;
                                dput := true;
                            else
                                case skind is
                                    when 1 =>
                                        if dm_cvalid = '1' and dm_ckey = ssrc(24 downto 3) then
                                            dval := byte_of(dm_cdata, ssrc(2 downto 0));
                                            dput := true;
                                        elsif dm_wbe /= "00" then
                                            dm_ret <= DM_BYTE;
                                            dm_st  <= DM_FLUSH;
                                        else
                                            dmr_addr <= ssrc(24 downto 3) & "000";
                                            dmr_we   <= '0';
                                            dmr_req  <= '1';
                                            dm_ckey  <= ssrc(24 downto 3);
                                            dm_st    <= DM_RWAIT;
                                        end if;
                                    when 2 =>
                                        dm_st <= DM_RRD;
                                    when 3 =>
                                        if pend_v = '1' then
                                            dval := stock_byte(stock_rgb, to_integer(dm_s(5 downto 0)));
                                        else
                                            dval := pal_v(to_integer(dm_s(5 downto 0)));
                                        end if;
                                        dput := true;
                                    when others =>
                                        dval := x"FF";      -- unmapped, or no XRAM
                                        dput := true;
                                end case;
                            end if;
                        end if;

                    when DM_RWAIT =>
                        if dmok then
                            dm_cdata  <= vx_rdata;
                            dm_cvalid <= '1';
                            dm_st     <= DM_BYTE;
                        end if;

                    when DM_RRD =>
                        -- the register space's read port, in a clock the CPU leaves it
                        if not (vic_cs = '1' and cpu_rd = '1') then
                            mem_raddr <= "10" & dm_s(15 downto 0);
                            dm_st <= DM_RR1;
                        end if;
                    when DM_RR1 =>
                        dm_st <= DM_RR2;
                    when DM_RR2 =>
                        dm_map(dm_ds, dm_t, dkind, sdst);
                        dval := regs_q;
                        dput := true;
                    when DM_PUT =>
                        dm_map(dm_ds, dm_t, dkind, sdst);
                        dval := dm_val;
                        dput := true;

                    when DM_FLUSH =>
                        if dm_wvram = '1' then
                            -- VRAM: into the port write queue, updating the copies
                            if wqc < 16 then
                                wq_addr(to_integer(wqw)) <= dm_wa(16 downto 1) & '0';
                                wq_data(to_integer(wqw)) <= dm_wd;
                                wq_be(to_integer(wqw))   <= dm_wbe;
                                wqw := wqw + 1;
                                wqc := wqc + 1;
                                a := resize(dm_wa(16 downto 0) - to_unsigned(VRAM_BASE mod 131072, 17), 18);
                                for ln in 0 to 1 loop
                                    if dm_wbe(ln) = '1' then
                                        bi := to_integer(a(2 downto 1) & to_unsigned(ln, 1));
                                        for q in 0 to 1 loop
                                            if has_blk(bv, ba, q, a) then
                                                bd(q)(8 * bi + 7 downto 8 * bi) := dm_wd(8 * ln + 7 downto 8 * ln);
                                            end if;
                                        end loop;
                                    end if;
                                end loop;
                                if (eng = E_RREQ or eng = E_RWAIT) and f_dma = '0' and f_line = '0' and
                                   f_blk = a(16 downto 3) then
                                    stale_v := '1';
                                end if;
                                dm_wbe <= "00";
                                dm_st  <= dm_ret;
                            end if;
                        else
                            dmr_addr <= dm_wa;
                            dmr_we   <= '1';
                            dmr_req  <= '1';
                            dm_st    <= DM_WWAIT;
                        end if;
                    when DM_WWAIT =>
                        if dmok then
                            dm_wbe <= "00";
                            dm_st  <= dm_ret;
                        end if;

                    when DM_NEXT =>
                        dm_c64 <= '0';
                        dn := dm_n;
                        if unsigned(dsc_next(dn)) < 4 and
                           dm_ran(to_integer(unsigned(dsc_next(dn)(1 downto 0)))) = '0' then
                            dm_n  <= to_integer(unsigned(dsc_next(dn)(1 downto 0)));
                            dm_st <= DM_START;
                        else
                            dm_busy <= '0';
                            if dm_irqp = '1' then
                                irq_stat(1) <= '1';
                            end if;
                            dm_st <= DM_IDLE;
                        end if;
                end case;

                -- a register-space store waits for a clock without a CPU write
                if dput and dkind = 2 and vic_cs = '1' and cpu_wr = '1' and
                   not (dm_op = "10" and dval = dm_tr) then
                    dput   := false;
                    dm_val <= dval;
                    dm_st  <= DM_PUT;
                end if;

                -- a byte to store
                if dput then
                    if not (dm_op = "10" and dval = dm_tr) then
                        case dkind is
                            when 1 =>
                                lane := to_integer(sdst(0 downto 0));
                                wb  := dm_wd;
                                wbe := dm_wbe;
                                wb(8 * lane + 7 downto 8 * lane) := dval;
                                wbe(lane) := '1';
                                dm_wd  <= wb;
                                dm_wbe <= wbe;
                                dm_wa  <= sdst;
                                if dm_ds = "01" then
                                    dm_wvram <= '1';
                                else
                                    dm_wvram <= '0';
                                end if;
                                -- the read cache sees the DMA's own writes
                                if dm_cvalid = '1' and dm_ckey = sdst(24 downto 3) then
                                    bb := dm_cdata;
                                    bb(8 * to_integer(sdst(2 downto 0)) + 7 downto 8 * to_integer(sdst(2 downto 0))) := dval;
                                    dm_cdata <= bb;
                                end if;
                            when 2 =>
                                -- one register-space store per clock the CPU leaves free
                                regs_we   <= '1';
                                mem_waddr <= "10" & dm_t(15 downto 0);
                                mem_wdata <= dval;
                                regs_snoop(dm_t(11 downto 0), dval);
                            when 3 =>
                                if pend_v = '1' then
                                    for k in 0 to PAL_LO_SZ - 1 loop
                                        pal_v(k) := stock_byte(stock_rgb, k);
                                    end loop;
                                    pend_v := '0';
                                end if;
                                pal_v(to_integer(dm_t(5 downto 0))) := dval;
                            when others =>
                                null;
                        end case;
                    end if;
                    dm_i  <= dm_i + 1;
                    dm_s  <= dm_s + 1;
                    dm_t  <= dm_t + 1;
                    dm_st <= DM_BYTE;
                end if;
            end if;

            pal_lo   <= pal_v;
            pal_pend <= pend_v;

            -- start of a raster line: latch CTRL and the layer order (the
            -- layers take their own setups)
            if line_start = '1' then
                line_ctrl <= ctrl;
                -- higher priority in front; ties: sprites, VIC-II, layer 0, layer 1
                if unsigned(s_order(1 downto 0)) >= unsigned(s_order(3 downto 2)) then
                    ord_l0_l1 <= '1';
                else
                    ord_l0_l1 <= '0';
                end if;
                if unsigned(s_order(5 downto 4)) >= unsigned(s_order(1 downto 0)) then
                    ord_vic_l0 <= '1';
                else
                    ord_vic_l0 <= '0';
                end if;
                if unsigned(s_order(5 downto 4)) >= unsigned(s_order(3 downto 2)) then
                    ord_vic_l1 <= '1';
                else
                    ord_vic_l1 <= '0';
                end if;
            end if;

            -- external VRAM engine: start the next request.  Queued writes
            -- go first, so a fetch always sees every write queued before it.
            if EXT_VRAM and eng = E_IDLE then
                if wqc > 0 and wq_count = 0 then
                    null;               -- a write queued this clock: next clock
                elsif wq_count > 0 then
                    addr_r <= std_logic_vector(to_unsigned(VRAM_BASE, 25) +
                                               resize(wq_addr(to_integer(wq_rd)), 25));
                    din_r  <= wq_data(to_integer(wq_rd));
                    be_r   <= wq_be(to_integer(wq_rd));
                    we_r  <= '1';
                    req_r <= '1';
                    eng   <= E_WREQ;
                else
                    issued := false;
                    for q in 0 to 1 loop
                        if region_of(port_addr(q)) = REG_VRAM and
                           not has_blk(bv, ba, q, port_addr(q)) then
                            f_blk   <= port_addr(q)(16 downto 3);
                            f_line  <= '0';
                            f_dma   <= '0';
                            stale_v := '0';
                            addr_r  <= std_logic_vector(to_unsigned(VRAM_BASE, 25) +
                                       resize(port_addr(q)(16 downto 3) & "000", 25));
                            we_r    <= '0';
                            req_r   <= '1';
                            eng     <= E_RREQ;
                            issued  := true;
                            exit;
                        end if;
                    end loop;
                    -- then the layers, taking turns
                    if not issued and line_start = '0' and u_req /= "00" and u_gnt = "00" then
                        if u_req(0) = '1' and (u_req(1) = '0' or u_pref = '0') then
                            dn := 0;
                        else
                            dn := 1;
                        end if;
                        u_pref    <= not u_pref;
                        u_gnt(dn) <= '1';
                        f_lu      <= dn;
                        f_line    <= '1';
                        f_dma     <= '0';
                        addr_r    <= std_logic_vector(to_unsigned(VRAM_BASE, 25) +
                                     resize(u_addr(dn) & "000", 25));
                        we_r      <= '0';
                        req_r     <= '1';
                        eng       <= E_RREQ;
                        issued    := true;
                    end if;
                    -- then the DMA engine
                    if not issued and dmr_req = '1' then
                        addr_r  <= std_logic_vector(dmr_addr);
                        din_r   <= dm_wd;
                        be_r    <= dm_wbe;
                        we_r    <= dmr_we;
                        req_r   <= '1';
                        dmr_req <= '0';
                        if dmr_we = '1' then
                            eng <= E_DWREQ;
                        else
                            f_dma  <= '1';
                            f_line <= '0';
                            eng    <= E_RREQ;
                        end if;
                    end if;
                end if;
            end if;

            blk_data  <= bd;
            blk_valid <= bv;
            blk_addr  <= ba;
            f_stale   <= stale_v;
            wq_count  <= wqc;
            wq_wr     <= wqw;

            -- read pipeline: stage 2 (memory data valid), stage 3 (output)
            rd_kind2   <= rd_kind;
            rd_val2 <= rd_val;
            rd_region2 <= rd_region;
            rd_pal2    <= rd_pal;
            rd_ext2    <= rd_ext;
            case rd_kind2 is
                when RD_DIRECT => dout <= rd_val2;
                when RD_PORT =>
                    case rd_region2 is
                        when REG_VRAM  =>
                            if EXT_VRAM then
                                dout <= rd_ext2;
                            else
                                dout <= vram_q;
                            end if;
                        when REG_REGS  => dout <= regs_q;
                        when REG_PALLO => dout <= rd_pal2;
                        when REG_ZERO  => dout <= x"00";
                        when others    => dout <= x"FF";
                    end case;
                when RD_NONE => null;
            end case;

            -- reset: lock, clear, stock palette, sweep the register space
            if reset = '1' then
                unlocked  <= '0';
                seq       <= 0;
                ctrl      <= (others => '0');
                irq_en    <= (others => '0');
                irq_stat  <= (others => '0');
                frame     <= (others => '0');
                win       <= (others => (others => '0'));
                port_addr <= (others => (others => '0'));
                port_step <= (others => (others => '0'));
                pal_pend  <= '1';
                sweeping  <= '1';
                sweep_ptr <= to_unsigned(PAL_LO_SZ, 12);
                vram_we   <= '0';
                regs_we   <= '0';
                rd_kind   <= RD_NONE;
                line_ctrl <= (others => '0');
                l_set     <= (others => (others => '0'));
                s_order   <= (others => '0');
                dm_st     <= DM_IDLE;
                dm_busy   <= '0';
                dm_c64    <= '0';
                dm_wbe    <= "00";
                dmr_req   <= '0';
                dsc_op    <= (others => (others => '0'));
                dsc_sp    <= (others => (others => '0'));
                dsc_fill  <= (others => (others => '0'));
                dsc_tr    <= (others => (others => '0'));
                dsc_next  <= (others => (others => '0'));
                dsc_src   <= (others => (others => '0'));
                dsc_dst   <= (others => (others => '0'));
                dsc_w     <= (others => (others => '0'));
                dsc_h     <= (others => (others => '0'));
                dsc_ss    <= (others => (others => '0'));
                dsc_ds    <= (others => (others => '0'));
                -- the copies go; a fetch in flight is thrown away when it
                -- lands; queued writes still go out
                blk_valid <= "00";
                if eng = E_RREQ or eng = E_RWAIT then
                    f_stale <= '1';
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- video.  With CTRL bit 3 set, VIC-II colour n shows palette entry n.
    -- In the window, the frontmost opaque layer shows unless the VIC-II is
    -- in front of it with an opaque pixel (background pixels are transparent
    -- with CTRL bit 4); the VIC-II's border stays on top of everything.
    -- Palette writes are immediate.

    video : process (clk)
        variable i       : natural range 0 to 15;
        variable li      : natural range 0 to 255;
        variable lay_rgb : std_logic_vector(23 downto 0);
        variable sh_ok   : std_logic;
        variable sh_vf   : std_logic;
        variable sh_rgb  : std_logic_vector(23 downto 0);
        variable vc      : std_logic_vector(23 downto 0);
        variable lc      : std_logic_vector(4 downto 0);
    begin
        if rising_edge(clk) then
            -- B: the frontmost layer pixel for vx_x (pal_q comes with it)
            b_idx  <= w_idx;
            b_ok   <= w_ok;
            b_vf   <= w_vf;
            b_late <= q_late(0) or q_late(1);

            li := to_integer(unsigned(b_idx));
            if li >= 16 then
                lay_rgb := pal_q;
            elsif pal_pend = '1' then
                lay_rgb := stock_rgb(li);
            else
                lay_rgb := pal_rgb(pal_lo, li);
            end if;

            -- the layer pixel for the VIC-II pixel now coming in
            late_r <= '0';
            if pix_ce = '1' then
                if vic_win = '1' then
                    sh_ok  := b_ok;
                    late_r <= b_late;
                    vx_x   <= vx_x + 1;
                else
                    sh_ok  := '0';
                end if;
                sh_vf   := b_vf;
                sh_rgb  := lay_rgb;
                cur_ok  <= sh_ok;
                cur_vf  <= sh_vf;
                cur_rgb <= sh_rgb;
            else
                sh_ok  := cur_ok;
                sh_vf  := cur_vf;
                sh_rgb := cur_rgb;
            end if;

            -- CTRL for this line: the first pixel comes with the latch
            if line_start = '1' then
                lc := ctrl;
            else
                lc := line_ctrl;
            end if;
            i := to_integer(unsigned(vic_idx));
            if lc(3) = '1' and pal_pend = '0' then
                vc := pal_rgb(pal_lo, i);
            else
                vc := vic_rgb;
            end if;
            if sh_ok = '1' and vic_border = '0' and
               (sh_vf = '0' or (lc(4) = '1' and vic_bg = '1')) then
                rgb_q <= sh_rgb;
            else
                rgb_q <= vc;
            end if;

            if line_start = '1' then
                vx_x <= (others => '0');
            end if;
        end if;
    end process;

end architecture;
