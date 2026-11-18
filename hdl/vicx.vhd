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
-- Wide window
--   $20842-$20845 move the window's left, right, top and bottom edges out
--   into the border, up to 32 pixels each side, 35 lines up and 37 down
--   (the visible frame); top and bottom are latched per frame, left and
--   right per line.  Layers and sprites count pixels from the widened
--   corner.  The horizontal position comes from counting pix_ce from
--   line_start, with the 320x200 area's first pixel learned from vic_win.
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
-- XRAM windows (CAP_FEAT bit 4)
--   bus_addr is the address of the CPU's access, or the REU's on the C64
--   side; win_hit says a window takes it, and win_addr is the SDRAM
--   address it goes to instead (the core makes the access a RAM access
--   there, so it reads and writes XRAM over RAM, ROM, I/O and cartridge).
--
-- DMA engine (EXT_VRAM and CAP_FEAT bit 3)
--   Every space is reached through the vx_* port: C64 RAM at C64_BASE, VRAM
--   at VRAM_BASE, XRAM (the REU's memory, xram_mb MB) at XRAM_BASE.  The
--   engine works a byte at a time from an 8-byte read cache and writes words
--   (two bytes) at a time; VRAM writes go through the port write queue, so
--   the port copies stay right.  It takes the port after the CPU's writes,
--   the port fetches and the line fetch, and not at all while a layer or the
--   sprite engine is fetching its line (u_busy): a read slipped in between
--   two of their blocks brings four queued writes that go before them, and
--   that made a layer late once the window starts early in the line (seen
--   on the MiSTer as black lines while the blitter ran during the display;
--   tb_vicx_step2 with DMA and WX 40).  While a descriptor that touches C64
--   RAM runs, cpu_halt is high; the core holds the CPU the way the VIC-II's
--   BA does.
--   Optional operations (CAP_BLIT generic, read at $D05B): bit 0 expand and
--   masked expand (operations 3, 4), a source byte per 8 destination
--   pixels, most significant bit first; bit 1 remap (operation 5): the
--   256-byte table is read from VRAM through the read cache as the
--   descriptor starts, into a block RAM, and each byte is looked up there
--   (two more clocks a byte); bit 3 mirror and backwards (+1 bits 6-7):
--   each byte's source and destination come from its row start and its
--   pixel in the row (DM_SEEK finds the first, with a multiply for a
--   backwards 2D transfer).  Strides are signed on every build.  Bit 2
--   scaled copy (operation 6): source row (r * Y step) >> 8 and byte
--   (x * X step) >> 8 (DM_SEEK works out each row's start from its number,
--   for every operation).  Bit 4 lists in VRAM (DMA_CMD bit 2): each
--   entry's bytes 0-27 come through the read cache into a fifth descriptor
--   slot (4) as its turn comes, and it runs from there.
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
        -- optional blitter operations (CAP_BLIT, $D05B); so far bit 0,
        -- expand and masked expand
        CAP_BLIT     : std_logic_vector(7 downto 0) := x"00";
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
        cpu_halt     : out std_logic;                      -- DMA touching C64 RAM: hold the CPU

        -- XRAM windows: the address of the CPU's (or the REU's) access to
        -- C64 memory, and whether a window takes it, with its SDRAM address
        bus_addr     : in  std_logic_vector(15 downto 0) := (others => '0');
        win_hit      : out std_logic;
        win_addr     : out std_logic_vector(24 downto 0)
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
    type eng_t      is (E_IDLE, E_WREQ, E_DWREQ, E_RREQ);
    -- reads in flight, oldest first (data come back in order): a port's
    -- block, a layer's or the sprites' block, or the DMA's
    type rqk_t      is (K_PORT, K_LINE, K_DMA);
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
    constant HAS_EXPAND : boolean := HAS_DMA and CAP_BLIT(0) = '1';
    constant HAS_REMAP  : boolean := HAS_DMA and CAP_BLIT(1) = '1';
    constant HAS_DIR    : boolean := HAS_DMA and CAP_BLIT(3) = '1';
    constant HAS_SCALED : boolean := HAS_DMA and CAP_BLIT(2) = '1';
    constant HAS_LIST   : boolean := HAS_DMA and CAP_BLIT(4) = '1';
    function blit_caps return std_logic_vector is
        variable c : std_logic_vector(7 downto 0) := x"00";
    begin
        if HAS_EXPAND then c(0) := '1'; end if;
        if HAS_REMAP then c(1) := '1'; end if;
        if HAS_SCALED then c(2) := '1'; end if;
        if HAS_DIR then c(3) := '1'; end if;
        if HAS_LIST then c(4) := '1'; end if;
        return c;
    end function;
    -- descriptors 0-3, and 4: the list entry being run
    type d8_t  is array (0 to 4) of std_logic_vector(7 downto 0);
    type d16_t is array (0 to 4) of unsigned(15 downto 0);
    type d24_t is array (0 to 4) of unsigned(23 downto 0);
    -- the four descriptors at $20880, as written (the fields the engine uses)
    signal dsc_op, dsc_sp, dsc_fill, dsc_tr, dsc_next : d8_t := (others => (others => '0'));
    signal dsc_src, dsc_dst : d24_t := (others => (others => '0'));
    signal dsc_w, dsc_h, dsc_ss, dsc_ds : d16_t := (others => (others => '0'));
    signal dsc_tbl    : d24_t := (others => (others => '0'));   -- remap table (+21-+23)
    signal dsc_xs, dsc_ys : d16_t := (others => (others => '0')); -- scaled steps (+24-+27)
    -- remap: the table, loaded from VRAM as the descriptor starts
    type lut_t is array (0 to 255) of std_logic_vector(7 downto 0);
    signal lut        : lut_t;
    signal lut_we     : std_logic := '0';
    signal lut_wa, lut_ra : unsigned(7 downto 0) := (others => '0');
    signal lut_wd, lut_q  : std_logic_vector(7 downto 0) := (others => '0');
    signal dm_tbl     : unsigned(23 downto 0) := (others => '0');
    signal dm_ti      : unsigned(8 downto 0) := (others => '0');
    type dmst_t is (DM_IDLE, DM_START, DM_BYTE, DM_RWAIT, DM_RRD, DM_RR1, DM_RR2,
                  DM_PUT, DM_FLUSH, DM_WWAIT, DM_NEXT,
                  DM_TLOAD, DM_TWAIT, DM_LUT1, DM_LUT2, DM_SEEK,
                  DM_LFETCH, DM_LWAIT);
    signal dm_st      : dmst_t := DM_IDLE;
    signal dm_ret     : dmst_t := DM_IDLE;          -- where a flush goes back to
    signal dm_busy    : std_logic := '0';
    signal dm_c64     : std_logic := '0';
    signal dm_n       : natural range 0 to 4 := 0;
    signal dm_ran     : std_logic_vector(4 downto 0) := (others => '0');
    -- lists in VRAM: the list address ($2085C-$2085E, as last written), and
    -- while one runs: the entry's address, how many ran, the byte fetched
    signal dm_lreg    : unsigned(23 downto 0) := (others => '0');
    signal dm_list    : std_logic := '0';
    signal dm_la      : unsigned(23 downto 0) := (others => '0');
    signal dm_lc      : unsigned(11 downto 0) := (others => '0');
    signal dm_lk      : unsigned(4 downto 0) := (others => '0');
    signal dm_irqp    : std_logic := '0';
    signal dm_op      : std_logic_vector(2 downto 0) := "000";
    signal dm_ex      : std_logic := '0';           -- expand or masked expand
    signal dm_ss      : std_logic_vector(1 downto 0) := "00";
    signal dm_ds      : std_logic_vector(1 downto 0) := "00";
    signal dm_fill    : std_logic_vector(7 downto 0) := (others => '0');
    signal dm_tr      : std_logic_vector(7 downto 0) := (others => '0');
    signal dm_s, dm_t, dm_srow, dm_trow : unsigned(23 downto 0) := (others => '0');
    signal dm_sst, dm_dst : unsigned(15 downto 0) := (others => '0');
    signal dm_w, dm_i, dm_h, dm_r : unsigned(15 downto 0) := (others => '0');
    signal dm_x       : unsigned(15 downto 0) := (others => '0');  -- source pixel in the row
    signal dm_mir, dm_bwd : std_logic := '0';       -- mirror, backwards (+1 bits 6, 7)
    signal dm_sc      : std_logic := '0';           -- scaled copy
    signal dm_xs, dm_ys : unsigned(15 downto 0) := (others => '0');  -- its steps, 8.8
    signal dm_s0, dm_t0 : unsigned(23 downto 0) := (others => '0');  -- source, destination
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
    signal cur_k      : rqk_t := K_PORT;          -- the read being requested
    signal rq_n       : natural range 0 to 2 := 0;
    signal rq_k0, rq_k1 : rqk_t := K_PORT;
    signal rq_u0, rq_u1 : natural range 0 to 2 := 0;
    signal pf_busy    : std_logic := '0';         -- a port fetch requested or in flight
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

    -- this line: each source's place in the order, 0 = in front
    -- (sprites, sprites behind, VIC-II, layer 0, layer 1)
    type pos_t is array (0 to 4) of unsigned(2 downto 0);
    constant SP_SPR   : natural := 0;
    constant SP_BEH   : natural := 1;
    constant SP_VIC   : natural := 2;
    constant SP_L0    : natural := 3;
    constant SP_L1    : natural := 4;
    signal line_pos   : pos_t := ("000", "001", "010", "011", "100");
    constant HAS_SPR  : boolean := CAP_FEAT(2) = '1';

    -- the layers and their fetches
    -- fetch clients: layer 0, layer 1, sprites
    type uaddr_t is array (0 to 2) of unsigned(13 downto 0);
    type uidx_t  is array (0 to 1) of std_logic_vector(7 downto 0);
    signal u_req      : std_logic_vector(2 downto 0);
    signal u_addr     : uaddr_t;
    signal u_gnt      : std_logic_vector(2 downto 0) := "000";
    signal u_busy     : std_logic_vector(2 downto 0);   -- a client is fetching its line
    signal u_valid    : std_logic_vector(2 downto 0) := "000";
    signal u_data     : std_logic_vector(63 downto 0) := (others => '0');
    signal u_pref     : std_logic := '0';          -- whose turn when both ask
    signal f_lu       : natural range 0 to 2 := 0;
    signal q_idx      : uidx_t;
    signal q_ok       : std_logic_vector(1 downto 0);
    signal q_late     : std_logic_vector(1 downto 0);
    signal win_y      : unsigned(8 downto 0);
    signal in_win     : std_logic;

    -- the wide window: edges as written ($20842-$20845: left, right, top,
    -- bottom), top and bottom latched per frame, left and right per line,
    -- each stopped at the edge of the visible frame (VICE's PAL screen:
    -- 32 pixels each side, 35 lines above the 320x200 area, 37 below)
    type wide_t is array (0 to 3) of unsigned(7 downto 0);
    signal s_wide     : wide_t := (others => (others => '0'));
    signal f_top      : unsigned(5 downto 0) := (others => '0');
    signal f_bot      : unsigned(5 downto 0) := (others => '0');
    signal l_left     : unsigned(5 downto 0) := (others => '0');
    signal l_right    : unsigned(5 downto 0) := (others => '0');
    signal c_left, c_right : unsigned(5 downto 0);
    signal win_w      : unsigned(8 downto 0);        -- this line's window width
    signal win_first  : unsigned(8 downto 0);        -- the window's first and last raster lines
    signal win_last   : unsigned(8 downto 0);
    signal line_in    : std_logic := '0';            -- this line is in the window
    signal hx         : unsigned(8 downto 0) := (others => '0');   -- pixel in the line
    signal wx0        : unsigned(8 downto 0) := to_unsigned(136, 9); -- the 320x200 area's first pixel
    signal vic_win_d  : std_logic := '0';
    signal in_wwin    : std_logic;                   -- the pixel coming in is in the window

    -- the sprite engine
    signal sp_front   : std_logic_vector(7 downto 0) := (others => '0');
    signal sp_behind  : std_logic_vector(7 downto 0) := (others => '0');
    signal sp_tw_we   : std_logic;
    signal sp_tw_a    : unsigned(11 downto 0);
    signal sp_tw_d    : std_logic_vector(7 downto 0);
    signal sp_preq    : std_logic := '0';
    signal sp_paddr   : unsigned(11 downto 0) := (others => '0');
    signal sp_pdata   : std_logic_vector(7 downto 0) := (others => '0');
    signal sp_pack    : std_logic := '0';
    signal sp_irq     : std_logic := '0';
    signal x_done     : std_logic;

    -- block RAM VRAM: a layer's block read a byte at a time, on clocks the
    -- CPU leaves the read port free
    signal br_busy    : std_logic := '0';
    signal br_u       : natural range 0 to 2 := 0;
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

    -- the order register as places, 0 = in front: higher priority first,
    -- ties sprite engine, VIC-II, layer 0, layer 1; sprites with the behind
    -- bit right behind the source that follows the sprite engine
    function order_pos(o : std_logic_vector(7 downto 0)) return pos_t is
        type four_t is array (0 to 3) of natural range 0 to 4;
        variable pri  : four_t;
        variable sq   : four_t := (SP_SPR, SP_VIC, SP_L0, SP_L1);
        variable t    : natural range 0 to 4;
        variable pos  : pos_t;
        variable n    : natural range 0 to 5 := 0;
        variable pend : boolean := false;
    begin
        pri(0) := to_integer(unsigned(o(7 downto 6)));     -- in sq's starting order
        pri(1) := to_integer(unsigned(o(5 downto 4)));
        pri(2) := to_integer(unsigned(o(1 downto 0)));
        pri(3) := to_integer(unsigned(o(3 downto 2)));
        -- stable sort of the four sources, high priority first
        for a in 0 to 2 loop
            for c in 2 downto 0 loop
                if c >= a and pri(c + 1) > pri(c) then
                    t := pri(c); pri(c) := pri(c + 1); pri(c + 1) := t;
                    t := sq(c); sq(c) := sq(c + 1); sq(c + 1) := t;
                end if;
            end loop;
        end loop;
        for k in 0 to 3 loop
            pos(sq(k)) := to_unsigned(n, 3);
            n := n + 1;
            if sq(k) = SP_SPR then
                pend := true;
            elsif pend then
                pos(SP_BEH) := to_unsigned(n, 3);
                n := n + 1;
                pend := false;
            end if;
        end loop;
        if pend then
            pos(SP_BEH) := to_unsigned(n, 3);
        end if;
        return pos;
    end function;

    function byte_of(d : std_logic_vector(63 downto 0); n : unsigned(2 downto 0))
        return std_logic_vector is
        variable i : natural range 0 to 7;
    begin
        i := to_integer(n);
        return d(8 * i + 7 downto 8 * i);
    end function;

begin

    -- the remap table: one write and one registered read a clock
    lut_mem : process (clk)
    begin
        if rising_edge(clk) then
            if lut_we = '1' then
                lut(to_integer(lut_wa)) <= lut_wd;
            end if;
            lut_q <= lut(to_integer(lut_ra));
        end if;
    end process;

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

    -- XRAM windows: W0 and W1, each in one of the slots $2000, $4000,
    -- $6000, $8000, $A000 or $E000 (codes 0-5) when bit 7 of its slot
    -- register is set; W0 wins if both sit in one slot.  Page n of XRAM
    -- (8 KB each) shows there, over RAM, ROM and cartridge whatever $01
    -- says.  Without XRAM no window takes an access (VICE reads $FF there).
    win_dec : process (bus_addr, win, xram_mb, xmask)
        variable code : integer range -1 to 5;
        variable hit  : boolean;
        variable xa   : unsigned(23 downto 0);
    begin
        case bus_addr(15 downto 13) is
            when "001"  => code := 0;
            when "010"  => code := 1;
            when "011"  => code := 2;
            when "100"  => code := 3;
            when "101"  => code := 4;
            when "111"  => code := 5;
            when others => code := -1;
        end case;
        hit := false;
        xa  := (others => '0');
        for w in 1 downto 0 loop                    -- W0 last, so it wins
            if code >= 0 and win(3 * w + 2)(7) = '1' and
               to_integer(unsigned(win(3 * w + 2)(2 downto 0))) = code then
                hit := true;
                xa  := unsigned(win(3 * w + 1)(2 downto 0)) & unsigned(win(3 * w)) &
                       unsigned(bus_addr(12 downto 0));
            end if;
        end loop;
        if hit and unsigned(xram_mb) /= 0 then
            win_hit <= '1';
        else
            win_hit <= '0';
        end if;
        win_addr <= std_logic_vector(to_unsigned(XRAM_BASE, 25) + resize(xa and xmask, 25));
    end process;

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

    -- the window: lines from the frame's top edge, width from the edges as
    -- written (each layer and the sprites latch it at line_start)
    c_left    <= to_unsigned(32, 6) when s_wide(0) > 32 else s_wide(0)(5 downto 0);
    c_right   <= to_unsigned(32, 6) when s_wide(1) > 32 else s_wide(1)(5 downto 0);
    win_w     <= to_unsigned(320, 9) + c_left + c_right;
    win_first <= to_unsigned(WIN_TOP, 9) - f_top;
    win_last  <= to_unsigned(WIN_TOP + 199, 9) + f_bot;
    win_y     <= unsigned(raster_y) - win_first;
    in_win    <= '1' when unsigned(raster_y) >= win_first and unsigned(raster_y) <= win_last else '0';
    in_wwin   <= '1' when line_in = '1' and (vic_win = '1' or (hx + l_left >= wx0 and hx < wx0 + 320 + l_right)) else '0';

    -- the two layers

    gen_layers : for n in 0 to 1 generate
        lay : entity work.vicx_layer
            generic map (HAS_TILES => HAS_TILES, HAS_BMP => HAS_BMP)
            port map (
                clk => clk, reset => reset,
                line_start => line_start, enable => ctrl(n),
                win_y => win_y, in_win => in_win, width => win_w, setup => l_set(n),
                f_req => u_req(n), f_addr => u_addr(n), f_gnt => u_gnt(n),
                f_valid => u_valid(n), f_data => u_data, f_busy => u_busy(n),
                x => vx_x, q_idx => q_idx(n), q_ok => q_ok(n), q_late => q_late(n));
    end generate;

    -- the frontmost opaque source other than the VIC-II (the VIC-II's
    -- place in the order is settled per pixel in the video process)
    winner : process (q_idx, q_ok, sp_front, sp_behind, line_pos, line_ctrl)
        variable best : unsigned(2 downto 0);
        variable idx  : std_logic_vector(7 downto 0);
        variable ok   : std_logic;
    begin
        best := "111";
        idx  := x"00";
        ok   := '0';
        if q_ok(0) = '1' and line_pos(SP_L0) < best then
            best := line_pos(SP_L0); idx := q_idx(0); ok := '1';
        end if;
        if q_ok(1) = '1' and line_pos(SP_L1) < best then
            best := line_pos(SP_L1); idx := q_idx(1); ok := '1';
        end if;
        if HAS_SPR and line_ctrl(2) = '1' then
            if sp_front /= x"00" and line_pos(SP_SPR) < best then
                best := line_pos(SP_SPR); idx := sp_front; ok := '1';
            end if;
            if sp_behind /= x"00" and line_pos(SP_BEH) < best then
                best := line_pos(SP_BEH); idx := sp_behind; ok := '1';
            end if;
        end if;
        w_idx <= idx;
        w_ok  <= ok;
        if line_pos(SP_VIC) < best then
            w_vf <= '1';
        else
            w_vf <= '0';
        end if;
    end process;

    -- the sprite engine and what it hears of the register space
    x_done   <= pix_ce and in_wwin;
    sp_tw_a  <= sweep_ptr when sweeping = '1' else mem_waddr(11 downto 0);
    sp_tw_d  <= x"00" when sweeping = '1' else mem_wdata;
    sp_tw_we <= '1' when (regs_we = '1' or sweeping = '1') and sp_tw_a(11 downto 10) = "01" else '0';

    gen_spr : if HAS_SPR generate
        spr : entity work.vicx_sprites
            port map (
                clk => clk, reset => reset,
                tw_we => sp_tw_we, tw_addr => sp_tw_a(9 downto 0), tw_data => sp_tw_d,
                frame_start => frame_start, line_start => line_start,
                raster_y => unsigned(raster_y), line_on => ctrl(2),
                win_first => win_first, win_last => win_last, width => win_w,
                f_req => u_req(2), f_addr => u_addr(2), f_gnt => u_gnt(2),
                f_valid => u_valid(2), f_data => u_data, f_busy => u_busy(2),
                x => vx_x, x_done => x_done, q_front => sp_front, q_behind => sp_behind,
                p_req => sp_preq, p_addr => sp_paddr, p_data => sp_pdata, p_ack => sp_pack,
                coll_irq => sp_irq);
    end generate;
    gen_nospr : if not HAS_SPR generate
        u_req(2)  <= '0';
        u_addr(2) <= (others => '0');
        u_busy(2) <= '0';
    end generate;

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
        variable dsrcv   : boolean;                -- dval is a source byte
        variable dskip   : boolean;                -- masked: not stored
        variable ta      : unsigned(24 downto 0);  -- remap table byte's SDRAM address
        variable sr, tr2 : unsigned(23 downto 0);  -- row starts
        variable prod    : signed(32 downto 0);
        variable ra, ri  : unsigned(15 downto 0);   -- row, source row
        variable yp      : unsigned(31 downto 0);
        variable sdst    : unsigned(24 downto 0);  -- SDRAM address of the destination
        variable ssrc    : unsigned(24 downto 0);
        variable dkind   : natural range 0 to 3;   -- 0 nothing, 1 SDRAM, 2 regs, 3 low palette
        variable skind   : natural range 0 to 3;
        variable lane    : natural range 0 to 1;
        variable wb      : std_logic_vector(15 downto 0);
        variable wbe     : std_logic_vector(1 downto 0);
        variable wbv     : std_logic_vector(7 downto 0);
        variable dn      : natural range 0 to 4;
        variable rbusy   : boolean;                -- the register-space write port is taken
        variable rqn     : natural range 0 to 2;
        variable k0, k1  : rqk_t;
        variable u0, u1  : natural range 0 to 2;
        variable needp   : boolean;

        -- a store to the register space (CPU port or DMA): what the display
        -- and the DMA engine keep copies of
        -- descriptor q's field at byte off
        procedure dsc_put(q : natural range 0 to 4; off : natural range 0 to 31;
                          d : std_logic_vector(7 downto 0)) is
        begin
            case off is
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
                when 21 => dsc_tbl(q)(7 downto 0)   <= unsigned(d);
                when 22 => dsc_tbl(q)(15 downto 8)  <= unsigned(d);
                when 23 => dsc_tbl(q)(23 downto 16) <= unsigned(d);
                when 24 => dsc_xs(q)(7 downto 0)  <= unsigned(d);
                when 25 => dsc_xs(q)(15 downto 8) <= unsigned(d);
                when 26 => dsc_ys(q)(7 downto 0)  <= unsigned(d);
                when 27 => dsc_ys(q)(15 downto 8) <= unsigned(d);
                when others => null;
            end case;
        end procedure;

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
            case to_integer(ra) is                       -- wide window edges
                when 16#842# => s_wide(0) <= unsigned(d);
                when 16#843# => s_wide(1) <= unsigned(d);
                when 16#844# => s_wide(2) <= unsigned(d);
                when 16#845# => s_wide(3) <= unsigned(d);
                when others  => null;
            end case;
            if ra(11 downto 7) = "10001" then           -- DMA descriptors
                dsc_put(to_integer(ra(6 downto 5)), to_integer(ra(4 downto 0)), d);
            end if;
            case to_integer(ra) is                       -- the DMA list's address
                when 16#85C# => dm_lreg(7 downto 0)   <= unsigned(d);
                when 16#85D# => dm_lreg(15 downto 8)  <= unsigned(d);
                when 16#85E# => dm_lreg(23 downto 16) <= unsigned(d);
                when others  => null;
            end case;
        end procedure;

        -- source pixel x of the rows starting at sr and tr: dm_s, dm_t
        -- (expand: a source byte per 8 pixels; mirror: x goes to w - 1 - x)
        procedure dm_pos(sr, tr : unsigned(23 downto 0); x : unsigned(15 downto 0)) is
            variable so, dof : unsigned(15 downto 0);
            variable xp      : unsigned(31 downto 0);
        begin
            xp := x * dm_xs;
            if dm_ex = '1' then
                so := shift_right(x, 3);
            elsif HAS_SCALED and dm_sc = '1' then
                so := xp(23 downto 8);              -- scaled: (x * X step) >> 8
            else
                so := x;
            end if;
            if dm_mir = '1' then dof := dm_w - 1 - x; else dof := x; end if;
            dm_s <= sr + resize(so, 24);
            dm_t <= tr + resize(dof, 24);
            dm_x <= x;
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
            u_gnt   <= "000";
            u_valid <= "000";
            sp_pack <= '0';
            rbusy   := vic_cs = '1' and cpu_wr = '1';
            dmok    := false;

            bd := blk_data;
            bv := blk_valid;
            ba := blk_addr;
            stale_v := f_stale;
            wqc := wq_count;
            wqw := wq_wr;

            -- external VRAM engine: finish what is in hand first, so the CPU
            -- access below sees a block that arrives in this clock
            rqn := rq_n;
            k0 := rq_k0; k1 := rq_k1;
            u0 := rq_u0; u1 := rq_u1;
            if EXT_VRAM then
                -- the oldest read's data
                if vx_rvalid = '1' and rqn > 0 then
                    case k0 is
                        when K_DMA =>
                            dmok := true;
                        when K_LINE =>
                            u_valid(u0) <= '1';
                            u_data <= vx_rdata;
                        when K_PORT =>
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
                            pf_busy <= '0';
                    end case;
                    k0 := k1; u0 := u1;
                    rqn := rqn - 1;
                end if;
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
                        -- taken: it joins the reads in flight
                        if vx_ack = '1' then
                            req_r <= '0';
                            if rqn = 0 then
                                k0 := cur_k; u0 := f_lu;
                            else
                                k1 := cur_k; u1 := f_lu;
                            end if;
                            rqn := rqn + 1;
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
                elsif line_start = '0' and u_req /= "000" and u_gnt = "000" then
                    -- layers first (taking turns), then the sprites
                    if u_req(0) = '1' and (u_req(1) = '0' or u_pref = '0') then
                        dn := 0;
                    elsif u_req(1) = '1' then
                        dn := 1;
                    else
                        dn := 2;
                    end if;
                    if dn < 2 then
                        u_pref <= not u_pref;
                    end if;
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
                                                if pf_busy = '1' and f_blk = a(16 downto 3) then
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
                                    -- DMA_CMD: start a chain, or with bit 2 a list
                                    -- in VRAM (where built); ignored while busy
                                    if HAS_DMA and dm_busy = '0' and cpu_din(2) = '0' then
                                        dm_busy <= '1';
                                        dm_list <= '0';
                                        dm_n    <= to_integer(unsigned(cpu_din(1 downto 0)));
                                        dm_ran  <= (others => '0');
                                        dm_irqp <= '0';
                                        dm_st   <= DM_START;
                                    elsif HAS_LIST and dm_busy = '0' then
                                        dm_busy <= '1';
                                        dm_list <= '1';
                                        dm_la   <= dm_lreg;
                                        dm_lc   <= (others => '0');
                                        dm_lk   <= (others => '0');
                                        dm_irqp <= '0';
                                        dm_cvalid <= '0';
                                        dm_st   <= DM_LFETCH;
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
                    when 16#5B# => v := blit_caps;              -- CAP_BLIT
                    when others => v := x"FF";          -- reserved, and $D06F
                end case;
                rd_val <= v;
            end if;

            -- DMA engine: one step per clock
            if HAS_DMA then
                dput := false;
                lut_we <= '0';
                dsrcv := false;
                dskip := false;
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
                        dm_op   <= dsc_op(dn)(2 downto 0);
                        if dsc_op(dn) = x"06" then dm_sc <= '1'; else dm_sc <= '0'; end if;
                        dm_xs   <= dsc_xs(dn);
                        dm_ys   <= dsc_ys(dn);
                        dm_s0   <= dsc_src(dn);
                        dm_t0   <= dsc_dst(dn);
                        if dsc_op(dn) = x"03" or dsc_op(dn) = x"04" then
                            dm_ex <= '1';
                        else
                            dm_ex <= '0';
                        end if;
                        if HAS_DIR then
                            dm_mir <= dsc_sp(dn)(6);
                            dm_bwd <= dsc_sp(dn)(7);
                        else
                            dm_mir <= '0';
                            dm_bwd <= '0';
                        end if;
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
                        -- (and optional ones this build lacks: expand without
                        -- CAP_BLIT bit 0, the direction bits 6-7)
                        if unsigned(dsc_op(dn)) > 6 or
                           (dsc_op(dn) = x"06" and not HAS_SCALED) or
                           (unsigned(dsc_op(dn)) > 2 and unsigned(dsc_op(dn)) < 5 and not HAS_EXPAND) or
                           (dsc_op(dn) = x"05" and not HAS_REMAP) or
                           (dsc_sp(dn)(7 downto 6) /= "00" and not HAS_DIR) or dsc_sp(dn)(3 downto 2) = "11" or
                           (dsc_op(dn) /= x"01" and dsc_sp(dn)(1 downto 0) = "11") or
                           dsc_w(dn) = 0 or (dsc_sp(dn)(4) = '1' and dsc_h(dn) = 0) then
                            dm_st <= DM_NEXT;
                        else
                            if dsc_sp(dn)(3 downto 2) = "00" or
                               (dsc_op(dn) /= x"01" and dsc_sp(dn)(1 downto 0) = "00") then
                                dm_c64 <= '1';
                            end if;
                            dm_tbl <= dsc_tbl(dn);
                            dm_ti  <= (others => '0');
                            dm_st  <= DM_SEEK;
                        end if;

                    -- each row's start, from its number: row ra (backwards: from
                    -- the last); scaled: source row (ra * Y step) >> 8; then the
                    -- row's first byte (backwards: its last pixel)
                    when DM_SEEK =>
                        if dm_bwd = '1' then ra := dm_h - 1 - dm_r; else ra := dm_r; end if;
                        yp := ra * dm_ys;
                        if HAS_SCALED and dm_sc = '1' then ri := yp(23 downto 8); else ri := ra; end if;
                        prod := signed('0' & ri) * signed(dm_sst);
                        sr   := dm_s0 + unsigned(prod(23 downto 0));
                        prod := signed('0' & ra) * signed(dm_dst);
                        tr2  := dm_t0 + unsigned(prod(23 downto 0));
                        dm_srow <= sr;
                        dm_trow <= tr2;
                        if dm_bwd = '1' then
                            dm_pos(sr, tr2, dm_w - 1);
                        else
                            dm_pos(sr, tr2, (others => '0'));
                        end if;
                        if HAS_REMAP and dm_op = "101" and dm_r = 0 then
                            dm_st <= DM_TLOAD;          -- the table, once
                        else
                            dm_st <= DM_BYTE;
                        end if;

                    -- a list entry: bytes 0-27 from VRAM through the read cache
                    -- into descriptor 4, then run it; an operation of $FF ends
                    -- the list
                    when DM_LFETCH =>
                        if HAS_LIST then
                            ta := to_unsigned(VRAM_BASE, 25) +
                                  resize((dm_la + resize(dm_lk, 24)) mod VRAM_SIZE, 25);
                            if dm_cvalid = '1' and dm_ckey = ta(24 downto 3) then
                                if dm_lk = 0 and byte_of(dm_cdata, ta(2 downto 0)) = x"FF" then
                                    dm_busy <= '0';
                                    dm_list <= '0';
                                    if dm_irqp = '1' then
                                        irq_stat(1) <= '1';
                                    end if;
                                    dm_st <= DM_IDLE;
                                else
                                    dsc_put(4, to_integer(dm_lk), byte_of(dm_cdata, ta(2 downto 0)));
                                    if dm_lk = 27 then
                                        dm_n   <= 4;
                                        dm_ran <= (others => '0');
                                        dm_st  <= DM_START;
                                    else
                                        dm_lk <= dm_lk + 1;
                                    end if;
                                end if;
                            else
                                dmr_addr <= ta(24 downto 3) & "000";
                                dmr_we   <= '0';
                                dmr_req  <= '1';
                                dm_ckey  <= ta(24 downto 3);
                                dm_st    <= DM_LWAIT;
                            end if;
                        end if;
                    when DM_LWAIT =>
                        if dmok then
                            dm_cdata  <= vx_rdata;
                            dm_cvalid <= '1';
                            dm_st     <= DM_LFETCH;
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
                                dm_st   <= DM_SEEK;         -- the next row's start
                            end if;
                        else
                            dm_map(dm_ds, dm_t, dkind, sdst);
                            dm_map(dm_ss, dm_s, skind, ssrc);
                            if dm_wbe /= "00" and
                               (dkind /= 1 or dm_wa(24 downto 1) /= sdst(24 downto 1)) then
                                -- the buffered word first
                                dm_ret <= DM_BYTE;
                                dm_st  <= DM_FLUSH;
                            elsif dm_op = "001" then
                                dval := dm_fill;
                                dput := true;
                            else
                                case skind is
                                    when 1 =>
                                        if dm_cvalid = '1' and dm_ckey = ssrc(24 downto 3) then
                                            dval  := byte_of(dm_cdata, ssrc(2 downto 0));
                                            dput  := true;
                                            dsrcv := true;
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
                                        dput  := true;
                                        dsrcv := true;
                                    when others =>
                                        dval  := x"FF";     -- unmapped, or no XRAM
                                        dput  := true;
                                        dsrcv := true;
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
                        dval  := regs_q;
                        dput  := true;
                        dsrcv := true;
                    when DM_PUT =>
                        dm_map(dm_ds, dm_t, dkind, sdst);
                        dval := dm_val;
                        dput := true;

                    -- remap: the table, a byte a clock through the read cache
                    when DM_TLOAD =>
                        if dm_ti(8) = '1' then
                            dm_st <= DM_BYTE;
                        else
                            ta := to_unsigned(VRAM_BASE, 25) +
                                  resize((dm_tbl + resize(dm_ti, 24)) mod VRAM_SIZE, 25);
                            if dm_cvalid = '1' and dm_ckey = ta(24 downto 3) then
                                lut_we <= '1';
                                lut_wa <= dm_ti(7 downto 0);
                                lut_wd <= byte_of(dm_cdata, ta(2 downto 0));
                                dm_ti  <= dm_ti + 1;
                            else
                                dmr_addr <= ta(24 downto 3) & "000";
                                dmr_we   <= '0';
                                dmr_req  <= '1';
                                dm_ckey  <= ta(24 downto 3);
                                dm_st    <= DM_TWAIT;
                            end if;
                        end if;
                    when DM_TWAIT =>
                        if dmok then
                            dm_cdata  <= vx_rdata;
                            dm_cvalid <= '1';
                            dm_st     <= DM_TLOAD;
                        end if;
                    -- remap: the looked-up byte, a clock after its address
                    when DM_LUT1 =>
                        dm_st <= DM_LUT2;
                    when DM_LUT2 =>
                        dm_map(dm_ds, dm_t, dkind, sdst);
                        dval := lut_q;
                        dput := true;

                    when DM_FLUSH =>
                        if dm_wvram = '1' then
                            -- VRAM: into the port write queue, updating the copies
                            -- (not while a layer or the sprites fetch: queued
                            -- writes go before their reads)
                            if wqc < 16 and u_busy = "000" then
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
                                if pf_busy = '1' and f_blk = a(16 downto 3) then
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
                        if HAS_LIST and dm_list = '1' then
                            -- the next entry, unless 4096 have run
                            dm_la <= dm_la + 32;
                            dm_lc <= dm_lc + 1;
                            dm_lk <= (others => '0');
                            if dm_lc = 4095 then
                                dm_busy <= '0';
                                dm_list <= '0';
                                if dm_irqp = '1' then
                                    irq_stat(1) <= '1';
                                end if;
                                dm_st <= DM_IDLE;
                            else
                                dm_st <= DM_LFETCH;
                            end if;
                        elsif unsigned(dsc_next(dn)) < 4 and
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

                -- expand: the source byte's bit for this pixel (most
                -- significant first) picks the fill or the transparent value
                if HAS_EXPAND and dput and dsrcv and dm_ex = '1' then
                    if dval(7 - to_integer(dm_x(2 downto 0))) = '1' then
                        dval := dm_fill;
                    else
                        dval := dm_tr;
                        if dm_op = "100" then
                            dskip := true;          -- masked expand: 0 leaves it
                        end if;
                    end if;
                end if;
                if (dm_op = "010" or ((dm_op = "101" or dm_op = "110") and dsrcv)) and dval = dm_tr then
                    dskip := true;                  -- masked copy, remap, scaled copy
                end if;
                -- remap: look the source byte up first (DM_LUT1, DM_LUT2)
                if HAS_REMAP and dput and dsrcv and dm_op = "101" and not dskip then
                    lut_ra <= unsigned(dval);
                    dput   := false;
                    dm_st  <= DM_LUT1;
                end if;

                -- a register-space store waits for a clock without a CPU write
                if dput and dkind = 2 and vic_cs = '1' and cpu_wr = '1' and not dskip then
                    dput   := false;
                    dm_val <= dval;
                    dm_st  <= DM_PUT;
                end if;

                -- a byte to store
                if dput then
                    if not dskip then
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
                                rbusy     := true;
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
                    if dm_bwd = '1' then
                        dm_pos(dm_srow, dm_trow, dm_x - 1);
                    else
                        dm_pos(dm_srow, dm_trow, dm_x + 1);
                    end if;
                    dm_st <= DM_BYTE;
                end if;
            end if;

            pal_lo   <= pal_v;
            pal_pend <= pend_v;

            -- start of a raster line: latch CTRL and the layer order (the
            -- layers take their own setups)
            if line_start = '1' then
                line_ctrl <= ctrl;
                line_pos  <= order_pos(s_order);
                l_left    <= c_left;
                l_right   <= c_right;
                line_in   <= in_win;
            end if;
            if frame_start = '1' then
                if s_wide(2) > 35 then f_top <= to_unsigned(35, 6); else f_top <= s_wide(2)(5 downto 0); end if;
                if s_wide(3) > 37 then f_bot <= to_unsigned(37, 6); else f_bot <= s_wide(3)(5 downto 0); end if;
            end if;

            -- the sprite engine's results into the register space, in clocks
            -- the CPU and the DMA leave the write port free
            if HAS_SPR then
                if sp_preq = '1' and sp_pack = '0' and not rbusy then
                    regs_we   <= '1';
                    mem_waddr <= "10" & "0000" & sp_paddr;
                    mem_wdata <= sp_pdata;
                    regs_snoop(sp_paddr, sp_pdata);
                    sp_pack   <= '1';
                end if;
                if sp_irq = '1' then
                    irq_stat(0) <= '1';
                end if;
            end if;

            -- external VRAM engine: start the next request.  Queued writes
            -- go first, so a fetch always sees every write queued before it.
            -- Writes, port fetches and DMA reads wait until no read is in
            -- flight; layer and sprite reads may follow one another (two in
            -- flight), unless a write or a port fetch is waiting.
            needp := false;
            for q in 0 to 1 loop
                if region_of(port_addr(q)) = REG_VRAM and not has_blk(bv, ba, q, port_addr(q)) then
                    needp := true;
                end if;
            end loop;
            if EXT_VRAM and eng = E_IDLE then
                if wqc > 0 and wq_count = 0 then
                    null;               -- a write queued this clock: next clock
                elsif wq_count > 0 and rqn > 0 then
                    null;               -- the write waits for the reads in flight
                elsif wq_count > 0 then
                    addr_r <= std_logic_vector(to_unsigned(VRAM_BASE, 25) +
                                               resize(wq_addr(to_integer(wq_rd)), 25));
                    din_r  <= wq_data(to_integer(wq_rd));
                    be_r   <= wq_be(to_integer(wq_rd));
                    we_r  <= '1';
                    req_r <= '1';
                    eng   <= E_WREQ;
                else
                    issued := needp and rqn > 0;    -- a port fetch waits: nothing else goes
                    for q in 0 to 1 loop
                        if rqn = 0 and region_of(port_addr(q)) = REG_VRAM and
                           not has_blk(bv, ba, q, port_addr(q)) then
                            f_blk   <= port_addr(q)(16 downto 3);
                            cur_k   <= K_PORT;
                            pf_busy <= '1';
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
                    if not issued and line_start = '0' and u_req /= "000" and u_gnt = "000" and
                       (rqn = 0 or (rqn = 1 and k0 = K_LINE)) then
                        if u_req(0) = '1' and (u_req(1) = '0' or u_pref = '0') then
                            dn := 0;
                        elsif u_req(1) = '1' then
                            dn := 1;
                        else
                            dn := 2;
                        end if;
                        if dn < 2 then
                            u_pref <= not u_pref;
                        end if;
                        u_gnt(dn) <= '1';
                        f_lu      <= dn;
                        cur_k     <= K_LINE;
                        addr_r    <= std_logic_vector(to_unsigned(VRAM_BASE, 25) +
                                     resize(u_addr(dn) & "000", 25));
                        we_r      <= '0';
                        req_r     <= '1';
                        eng       <= E_RREQ;
                        issued    := true;
                    end if;
                    -- then the DMA engine, only while no layer and not the
                    -- sprites are fetching: between two of their blocks a
                    -- DMA read and the writes it brings would take the slots
                    -- they need to keep ahead of the display
                    if not issued and dmr_req = '1' and rqn = 0 and u_busy = "000" then
                        addr_r  <= std_logic_vector(dmr_addr);
                        din_r   <= dm_wd;
                        be_r    <= dm_wbe;
                        we_r    <= dmr_we;
                        req_r   <= '1';
                        dmr_req <= '0';
                        if dmr_we = '1' then
                            eng <= E_DWREQ;
                        else
                            cur_k <= K_DMA;
                            eng   <= E_RREQ;
                        end if;
                    end if;
                end if;
            end if;

            rq_n  <= rqn;
            rq_k0 <= k0; rq_k1 <= k1;
            rq_u0 <= u0; rq_u1 <= u1;

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
                s_wide    <= (others => (others => '0'));
                f_top     <= (others => '0');
                f_bot     <= (others => '0');
                line_pos  <= order_pos(x"00");
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
                dsc_tbl   <= (others => (others => '0'));
                dsc_xs    <= (others => (others => '0'));
                dsc_ys    <= (others => (others => '0'));
                dsc_src   <= (others => (others => '0'));
                dsc_dst   <= (others => (others => '0'));
                dsc_w     <= (others => (others => '0'));
                dsc_h     <= (others => (others => '0'));
                dsc_ss    <= (others => (others => '0'));
                dsc_ds    <= (others => (others => '0'));
                -- the copies go; a fetch in flight is thrown away when it
                -- lands; queued writes still go out
                blk_valid <= "00";
                if pf_busy = '1' then
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

            -- where the 320x200 area starts in the line (learned from the
            -- VIC-II), and the pixel count
            if pix_ce = '1' then
                vic_win_d <= vic_win;
                if vic_win = '1' and vic_win_d = '0' then
                    wx0 <= hx;
                end if;
                hx <= hx + 1;
            end if;

            -- the layer pixel for the VIC-II pixel now coming in
            late_r <= '0';
            if pix_ce = '1' then
                if in_wwin = '1' then
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
            -- over the 320x200 area the border stays on top; in the widened
            -- part border pixels are background (transparent with bit 4)
            if sh_ok = '1' and not (vic_win = '1' and vic_border = '1') and
               (sh_vf = '0' or (lc(4) = '1' and (vic_bg = '1' or (vic_win = '0' and vic_border = '1')))) then
                rgb_q <= sh_rgb;
            else
                rgb_q <= vc;
            end if;

            if line_start = '1' then
                vx_x <= (others => '0');
                hx   <= (others => '0');
            end if;
        end if;
    end process;

end architecture;
