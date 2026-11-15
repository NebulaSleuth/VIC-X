-- VIC-X: graphics and memory extension for the C64 (spec 0.1, draft)
--
-- Step 1 of the FPGA block: the unlock, the ID and capability registers,
-- the two data ports with their auto-increment, VRAM, the register space
-- behind the ports, the palette, VIC-II colour remapping (CTRL bit 3), the
-- frame counter and the IRQ.  Layers, sprites, DMA and the XRAM windows come
-- in later steps; their registers already hold and read back their values.
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
--   the start of each raster line.  Each clock the block takes the VIC-II's
--   colour index and the core's RGB for it, and returns the RGB to show one
--   clock later.
--
-- Reset
--   reset locks VIC-X, clears CTRL, IRQ and the ports, and restores the
--   stock palette.  The register space is then cleared by a sweep of about
--   2,500 clocks; VRAM keeps its contents.

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
        CAP_FEAT     : std_logic_vector(7 downto 0) := x"00"
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
        rgb_out      : out std_logic_vector(23 downto 0)
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
    signal vram       : byte_array(0 to VRAM_SIZE - 1);
    signal regs       : byte_array(0 to REGSPACE_SZ - 1);

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

    -- video
    signal line_ctrl  : std_logic_vector(4 downto 0) := (others => '0');
    signal rgb_q      : std_logic_vector(23 downto 0) := (others => '0');

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

begin

    -- VIC-X owns $D040-$D06F while unlocked; the mirrors at $D100-$D3FF never
    claim <= '1' when vic_cs = '1' and unlocked = '1' and cpu_addr(9 downto 8) = "00"
                      and in_regs(to_integer(unsigned(cpu_addr(7 downto 0))))
             else '0';

    irq      <= '1' when (irq_stat and irq_en) /= "000" else '0';
    cpu_dout <= dout;
    rgb_out  <= rgb_q;

    ---------------------------------------------------------------------------
    -- memories: one read port and one write port each

    vram_mem : process (clk)
    begin
        if rising_edge(clk) then
            if vram_we = '1' then
                vram(to_integer(mem_waddr(VRAM_BITS - 1 downto 0))) <= mem_wdata;
            end if;
            vram_q <= vram(to_integer(mem_raddr(VRAM_BITS - 1 downto 0)));
        end if;
    end process;

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
    begin
        if rising_edge(clk) then
            vram_we <= '0';
            regs_we <= '0';
            rd_kind <= RD_NONE;

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
                                            vram_we <= '1';
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
                                when others => null;    -- read-only, reserved, DMA_CMD (later step)
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
                        mem_raddr <= a;
                        port_addr(p) <= stepped(a, port_step(p));
                    when 16#54# to 16#59# => v := win(off - 16#54#);
                    when 16#5A# => v := x"00";          -- DMA_CMD: never busy yet
                    when others => v := x"FF";          -- reserved, and $D06F
                end case;
                rd_val <= v;
            end if;

            pal_lo   <= pal_v;
            pal_pend <= pend_v;

            -- read pipeline: stage 2 (memory data valid), stage 3 (output)
            rd_kind2   <= rd_kind;
            rd_val2 <= rd_val;
            rd_region2 <= rd_region;
            rd_pal2    <= rd_pal;
            case rd_kind2 is
                when RD_DIRECT => dout <= rd_val2;
                when RD_PORT =>
                    case rd_region2 is
                        when REG_VRAM  => dout <= vram_q;
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
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- video: CTRL is latched at the start of each line; with bit 3 set,
    -- VIC-II colour n shows palette entry n.  Palette writes are immediate.

    video : process (clk)
        variable i : natural range 0 to 15;
    begin
        if rising_edge(clk) then
            if line_start = '1' then
                line_ctrl <= ctrl;
            end if;
            i := to_integer(unsigned(vic_idx));
            if line_ctrl(3) = '1' and pal_pend = '0' then
                rgb_q <= pal_rgb(pal_lo, i);
            else
                rgb_q <= vic_rgb;
            end if;
            if reset = '1' then
                line_ctrl <= (others => '0');
            end if;
        end if;
    end process;

end architecture;
