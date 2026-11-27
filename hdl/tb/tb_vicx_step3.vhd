-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Michael Hartman
--
-- Testbench for VIC-X step 3: two layers, tiles and bitmaps, scrolling and
-- the layer order.  Same video generator and SDRAM-port model as step 2,
-- now with border pixels inside the window too; every pixel is compared
-- with a reference that follows layer_line and mix_line in the VICE fork
-- (src/vicx/vicx.c) and conformance tests t15-t20.
--
-- With EXT, VRAM is behind a model of the SDRAM controller's VIC-X port that
-- takes a request only at the start of a VIC-X slot (4 of the 8 slots in
-- each C64 cycle, 3 with REU DMA running) and answers like the controller.
-- Run with hdl/run_sim.sh; prints PASS or the failures and exits 1.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.vicx_pkg.all;

entity tb_vicx_step3 is
    generic (
        EXT  : boolean := false;    -- VRAM through the vx_* port
        REU  : boolean := false;    -- REU DMA holds the DMA0 slot (EXT only)
        WX   : natural := 120       -- first window pixel in the line
    );
end entity;

architecture sim of tb_vicx_step3 is

    constant LINE_CLK  : natural := 63 * 32;
    constant LINE_PIX  : natural := LINE_CLK / 4;
    constant LINES     : natural := 312;

    type vram_t is array (0 to 131071) of std_logic_vector(7 downto 0);
    type pal_t  is array (0 to 255) of std_logic_vector(23 downto 0);
    type set_t  is array (0 to 31) of std_logic_vector(7 downto 0);
    type sets_t is array (0 to 1) of set_t;

    -- VRAM contents: plenty of zero bytes and zero nibbles
    function vram_byte(a : natural) return std_logic_vector is
        variable v : natural;
    begin
        v := (a * 73 + (a / 256) * 151 + (a / 4096) * 29) mod 256;
        if a mod 11 = 0 then
            v := 0;
        elsif a mod 13 = 0 then
            v := v mod 16;          -- high nibble 0
        elsif a mod 17 = 0 then
            v := (v / 16) * 16;     -- low nibble 0
        end if;
        return std_logic_vector(to_unsigned(v, 8));
    end function;

    function vram_init return vram_t is
        variable m : vram_t;
    begin
        for a in m'range loop
            m(a) := vram_byte(a);
        end loop;
        return m;
    end function;

    function stock_of(i : natural) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned(i * 16, 8)) &
               std_logic_vector(to_unsigned(i * 16 + 1, 8)) &
               std_logic_vector(to_unsigned(i * 16 + 2, 8));
    end function;

    function pal_init return pal_t is
        variable p : pal_t := (others => (others => '0'));
    begin
        for i in 0 to 15 loop
            p(i) := stock_of(i);
        end loop;
        return p;
    end function;

    -- the palette the test writes: entry i
    function pal_val(i : natural) return std_logic_vector is
        variable r : std_logic_vector(23 downto 0);
    begin
        r := std_logic_vector(to_unsigned((i * 37 + 5) mod 256, 8)) &
             std_logic_vector(to_unsigned((i * 91 + 11) mod 256, 8)) &
             std_logic_vector(to_unsigned((i * 53 + 200) mod 256, 8));
        return r;
    end function;

    signal clk       : std_logic := '0';
    signal reset     : std_logic := '0';
    signal vic_cs    : std_logic := '0';
    signal cpu_addr  : std_logic_vector(9 downto 0) := (others => '0');
    signal cpu_din   : std_logic_vector(7 downto 0) := (others => '0');
    signal cpu_wr    : std_logic := '0';
    signal cpu_rd    : std_logic := '0';
    signal claim     : std_logic;
    signal cpu_dout  : std_logic_vector(7 downto 0);
    signal irq       : std_logic;
    signal stock     : rgb_array;
    signal frame_st  : std_logic := '0';
    signal line_st   : std_logic := '0';
    signal pix_ce    : std_logic := '0';
    signal raster_y  : std_logic_vector(8 downto 0) := (others => '0');
    signal vic_bg    : std_logic := '0';
    signal vic_win   : std_logic := '0';
    signal vic_border : std_logic := '0';
    signal vic_idx   : std_logic_vector(3 downto 0) := (others => '0');
    signal vic_rgb   : std_logic_vector(23 downto 0) := (others => '0');
    signal rgb_out   : std_logic_vector(23 downto 0);
    signal lay_late  : std_logic;

    signal vx_req, vx_we, vx_ack, vx_rvalid, vx_miss : std_logic := '0';
    signal vx_addr   : std_logic_vector(24 downto 0);
    signal vx_din    : std_logic_vector(15 downto 0);
    signal vx_be     : std_logic_vector(1 downto 0);
    signal vx_rdata  : std_logic_vector(63 downto 0) := (others => '0');

    -- what the block should hold, kept by the stimulus
    signal ref_vram  : vram_t := vram_init;
    signal ref_pal   : pal_t := pal_init;
    signal ref_set   : sets_t := (others => (others => (others => '0')));
    signal ref_order : std_logic_vector(7 downto 0) := (others => '0');
    signal ref_ctrl  : std_logic_vector(7 downto 0) := (others => '0');

    signal checking  : boolean := false;
    signal done      : boolean := false;
    signal vid_err   : natural := 0;
    signal compared  : natural := 0;
    signal shown     : natural := 0;
    signal lates     : natural := 0;
    signal misses    : natural := 0;
    signal requests  : natural := 0;

    function hex(v : std_logic_vector) return string is
        constant digits : string(1 to 16) := "0123456789ABCDEF";
        variable r : string(1 to v'length / 4);
        variable x : std_logic_vector(v'length - 1 downto 0) := v;
    begin
        for i in r'range loop
            r(i) := digits(to_integer(unsigned(x(x'left - (i - 1) * 4 downto x'left - (i - 1) * 4 - 3))) + 1);
        end loop;
        return r;
    end function;

begin

    clk <= not clk after 5 ns when not done;

    stock_init : for i in 0 to 15 generate
        stock(i) <= stock_of(i);
    end generate;

    dut : entity work.vicx
        generic map (VRAM_BITS => 17, CAP_SPR => 0, CAP_SPRLINE => 0, CAP_FEAT => x"03",
                     EXT_VRAM => EXT)
        port map (
            clk => clk, reset => reset,
            vic_cs => vic_cs, cpu_addr => cpu_addr, cpu_din => cpu_din,
            cpu_wr => cpu_wr, cpu_rd => cpu_rd, claim => claim,
            cpu_dout => cpu_dout, irq => irq,
            xram_mb => x"00", stock_rgb => stock,
            frame_start => frame_st, line_start => line_st,
            vic_idx => vic_idx, vic_rgb => vic_rgb,
            pix_ce => pix_ce, raster_y => raster_y, vic_bg => vic_bg, vic_win => vic_win,
            vic_border => vic_border,
            rgb_out => rgb_out, lay_late => lay_late,
            vx_req => vx_req, vx_we => vx_we, vx_addr => vx_addr, vx_din => vx_din,
            vx_be => vx_be, vx_ack => vx_ack, vx_rdata => vx_rdata,
            vx_rvalid => vx_rvalid, vx_miss => vx_miss);

    ---------------------------------------------------------------------------
    -- the SDRAM controller's VIC-X port: a slot is 4 clocks, 8 slots a C64
    -- cycle; VIC-X may start in DMA0 (1) and CPU0/4/8 (4-6).  A request held
    -- at a slot's start is acknowledged in the next clock; read data come 5
    -- clocks after that (sdram_vicx.vhd: ack at e2, rvalid at e12).

    mem_model : process (clk)
        variable mem   : vram_t := vram_init;
        variable cnt   : natural := 0;
        type tq_t is array (0 to 3) of integer;
        type bq_t is array (0 to 3) of std_logic_vector(63 downto 0);
        variable tq    : tq_t := (others => -1);   -- reads in flight: clocks since taken
        variable bq    : bq_t;
        variable a     : natural;
        variable slot  : natural;
        variable blk   : std_logic_vector(63 downto 0);
    begin
        if rising_edge(clk) then
            vx_ack    <= '0';
            vx_rvalid <= '0';
            for k in 0 to 3 loop
                if tq(k) >= 0 then
                    tq(k) := tq(k) + 1;
                    if tq(k) = 5 then
                        vx_rdata  <= bq(k);
                        vx_rvalid <= '1';
                        tq(k) := -1;
                    end if;
                end if;
            end loop;
            slot := (cnt / 4) mod 8;
            if EXT and cnt mod 4 = 0 and vx_req = '1' and
               ((slot = 1 and not REU) or slot = 4 or slot = 5 or slot = 6) then
                a := to_integer(unsigned(vx_addr)) - 16#100000#;
                vx_ack <= '1';
                requests <= requests + 1;
                if vx_we = '1' then
                    if vx_be(0) = '1' then mem((a / 2) * 2) := vx_din(7 downto 0); end if;
                    if vx_be(1) = '1' then mem((a / 2) * 2 + 1) := vx_din(15 downto 8); end if;
                else
                    for n in 0 to 7 loop
                        blk(8 * n + 7 downto 8 * n) := mem((a / 8) * 8 + n);
                    end loop;
                    for k in 0 to 3 loop
                        if tq(k) < 0 then
                            tq(k) := 0;
                            bq(k) := blk;
                            exit;
                        end if;
                    end loop;
                end if;
            end if;
            cnt := cnt + 1;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- video: lines and pixels in, and every pixel out checked

    video : process
        variable px, ln     : natural := 0;
        variable ph         : natural := 0;
        variable s1         : natural := 12345;
        variable ctl        : std_logic_vector(7 downto 0) := (others => '0');
        variable ordr       : std_logic_vector(7 downto 0) := (others => '0');
        variable st         : sets_t := (others => (others => (others => '0')));
        variable exp        : std_logic_vector(23 downto 0);
        variable exp_ok     : boolean := false;
        variable exp_lay    : boolean := false;
        variable exp_x      : integer;
        variable exp_ln     : natural;
        variable idx        : natural;
        variable y, x       : natural;
        variable in_win     : boolean;
        variable bg         : std_logic;
        variable err_n, cmp_n, shown_n, late_n : natural := 0;
        type src_arr is array (0 to 2) of natural;     -- 0 VIC-II, 1 layer 0, 2 layer 1
        variable seq        : src_arr;
        variable pri        : src_arr;
        variable t          : natural;
        variable lp         : src_arr;
        variable done_px    : boolean;

        impure function rnd(m : natural) return natural is
        begin
            s1 := (s1 * 1103 + 12347) mod 65536;
            return (s1 / 16) mod m;
        end function;

        function u8(v : std_logic_vector) return natural is
        begin
            return to_integer(unsigned(v));
        end function;

        -- layer_line for one pixel
        impure function lay_px(l : set_t; yy, xx : natural) return natural is
            variable mode, m, dw : natural;
            variable base, stride, row, lx, tsize, tbytes, mapw, maph : natural;
            variable tbase, sx, sy, ly, py, maprow, tx, pxx, entry, r, trow, bank, n : natural;
            variable bpp8 : boolean;
            variable b : natural;
        begin
            mode := u8(l(0));
            m := mode mod 4;
            dw := (mode / 8) mod 2;
            base := (u8(l(4)) mod 2) * 65536 + u8(l(3)) * 256 + u8(l(2));
            if m >= 2 then
                stride := (u8(l(13)) mod 8) * 256 + u8(l(12));
                row := base + yy * stride;
                lx := xx / (2 ** dw);
                if m = 3 then
                    return u8(ref_vram((row + lx) mod 131072));
                end if;
                b := u8(ref_vram((row + lx / 2) mod 131072));
                if lx mod 2 = 0 then n := b / 16; else n := b mod 16; end if;
                if n = 0 then return 0; end if;
                return (u8(l(14)) mod 16) * 16 + n;
            end if;
            if (mode / 4) mod 2 = 1 then tsize := 16; else tsize := 8; end if;
            bpp8 := m = 1;
            if bpp8 then tbytes := tsize * tsize; else tbytes := tsize * tsize / 2; end if;
            mapw := 32 * 2 ** (u8(l(1)) mod 4);
            maph := 32 * 2 ** ((u8(l(1)) / 4) mod 4);
            tbase := (u8(l(7)) mod 2) * 65536 + u8(l(6)) * 256 + u8(l(5));
            sx := (u8(l(9)) mod 16) * 256 + u8(l(8));
            sy := (u8(l(11)) mod 16) * 256 + u8(l(10));
            ly := (yy + sy) mod (maph * tsize);
            py := ly mod tsize;
            maprow := base + (ly / tsize) * mapw * 2;
            lx := (xx / (2 ** dw) + sx) mod (mapw * tsize);
            tx := lx / tsize;
            pxx := lx mod tsize;
            entry := u8(ref_vram((maprow + tx * 2) mod 131072)) +
                     256 * u8(ref_vram((maprow + tx * 2 + 1) mod 131072));
            if (entry / 2048) mod 2 = 1 then r := tsize - 1 - py; else r := py; end if;
            if bpp8 then
                trow := tbase + (entry mod 1024) * tbytes + r * tsize;
            else
                trow := tbase + (entry mod 1024) * tbytes + r * tsize / 2;
            end if;
            bank := (entry / 4096) * 16;
            if (entry / 1024) mod 2 = 1 then pxx := tsize - 1 - pxx; end if;
            if bpp8 then
                return u8(ref_vram((trow + pxx) mod 131072));
            end if;
            b := u8(ref_vram((trow + pxx / 2) mod 131072));
            if pxx mod 2 = 0 then n := b / 16; else n := b mod 16; end if;
            if n = 0 then return 0; end if;
            return bank + n;
        end function;
    begin
        wait until rising_edge(clk);

        if lay_late = '1' then
            late_n := late_n + 1;
        end if;
        if exp_ok and checking then
            cmp_n := cmp_n + 1;
            if rgb_out /= exp then
                err_n := err_n + 1;
                if err_n <= 10 then
                    report "FAIL: line " & integer'image(exp_ln) & " x " & integer'image(exp_x) &
                           ": got $" & hex(rgb_out) & ", want $" & hex(exp) severity error;
                end if;
            elsif exp_lay then
                shown_n := shown_n + 1;
            end if;
        end if;
        exp_ok := false;

        if line_st = '1' then
            ctl  := ref_ctrl;
            st   := ref_set;
            ordr := ref_order;
            -- the order for this line: stable sort, high priority first,
            -- ties VIC-II, layer 0, layer 1
            pri(0) := u8(ordr(5 downto 4));
            pri(1) := u8(ordr(1 downto 0));
            pri(2) := u8(ordr(3 downto 2));
            seq := (0, 1, 2);
            for a in 1 to 2 loop
                for c in 2 downto 1 loop
                    if pri(seq(c)) > pri(seq(c - 1)) then
                        t := seq(c); seq(c) := seq(c - 1); seq(c - 1) := t;
                    end if;
                end loop;
            end loop;
        end if;

        if pix_ce = '1' then
            idx := to_integer(unsigned(vic_idx));
            if ctl(3) = '1' then
                exp := ref_pal(idx);
            else
                exp := stock_of(idx);
            end if;
            exp_lay := false;
            if vic_win = '1' and vic_border = '0' then
                y := to_integer(unsigned(raster_y)) - 51;
                x := px - WX;
                for n in 0 to 1 loop
                    lp(n + 1) := 0;
                    if ctl(n) = '1' then
                        lp(n + 1) := lay_px(st(n), y, x);
                    end if;
                end loop;
                done_px := false;
                for k in 0 to 2 loop
                    if not done_px then
                        if seq(k) = 0 then
                            if not (ctl(4) = '1' and vic_bg = '1') then
                                done_px := true;        -- an opaque VIC-II pixel
                            end if;
                        elsif lp(seq(k)) /= 0 then
                            exp := ref_pal(lp(seq(k)));
                            exp_lay := true;
                            done_px := true;
                        end if;
                    end if;
                end loop;
            end if;
            exp_ok := true;
            exp_x  := px - WX;
            exp_ln := to_integer(unsigned(raster_y));
        end if;

        -- drive the next clock
        line_st  <= '0';
        frame_st <= '0';
        pix_ce   <= '0';
        ph := ph + 1;
        if ph = 4 then
            ph := 0;
            px := px + 1;
            if px = LINE_PIX then
                px := 0;
                ln := (ln + 1) mod LINES;
            end if;
        end if;
        if ph = 0 then
            pix_ce <= '1';
            if px = 0 then
                line_st  <= '1';
                raster_y <= std_logic_vector(to_unsigned(ln, 9));
                if ln = 0 then
                    frame_st <= '1';
                end if;
            end if;
            in_win := ln >= 51 and ln < 251 and px >= WX and px < WX + 320;
            idx := rnd(16);
            vic_idx <= std_logic_vector(to_unsigned(idx, 4));
            vic_rgb <= stock_of(idx);
            vic_border <= '0';
            if in_win then
                vic_win <= '1';
                if rnd(20) = 0 then
                    vic_border <= '1';          -- the 38-column / 24-row border
                    vic_bg <= '0';
                else
                    if rnd(4) /= 0 then bg := '1'; else bg := '0'; end if;
                    vic_bg <= bg;
                end if;
            else
                vic_win <= '0';
                vic_bg  <= '0';
            end if;
        end if;

        vid_err  <= err_n;
        compared <= cmp_n;
        shown    <= shown_n;
        lates    <= late_n;
    end process;

    count_miss : process (clk)
    begin
        if rising_edge(clk) and vx_miss = '1' then
            misses <= misses + 1;
        end if;
    end process;

    ---------------------------------------------------------------------------

    stim : process
        variable errors : natural := 0;
        variable v      : std_logic_vector(7 downto 0);
        variable rd_a   : natural := 16#10000#;     -- port 1 read address
        variable wr_a   : natural := 16#1F000#;     -- port 0 write address

        procedure idle(n : natural) is
        begin
            for i in 1 to n loop
                wait until rising_edge(clk);
            end loop;
        end procedure;

        -- one CPU write to $D0xx, g clocks long
        procedure wr(addr : natural; val : natural; g : natural := 8) is
        begin
            cpu_addr <= std_logic_vector(to_unsigned(addr mod 1024, 10));
            cpu_din  <= std_logic_vector(to_unsigned(val, 8));
            vic_cs   <= '1';
            cpu_wr   <= '1';
            wait until rising_edge(clk);
            cpu_wr   <= '0';
            vic_cs   <= '0';
            idle(g - 1);
        end procedure;

        procedure rd(addr : natural; val : out std_logic_vector(7 downto 0); g : natural := 8) is
        begin
            cpu_addr <= std_logic_vector(to_unsigned(addr mod 1024, 10));
            vic_cs   <= '1';
            cpu_rd   <= '1';
            wait until rising_edge(clk);
            cpu_rd   <= '0';
            vic_cs   <= '0';
            idle(3);
            val      := cpu_dout;
            idle(g - 4);
        end procedure;

        procedure port_set(p : natural; a : natural; step : natural := 1) is
            constant r : natural := 16#D04C# + 4 * p;
        begin
            wr(r, a mod 256);
            wr(r + 1, (a / 256) mod 256);
            wr(r + 2, step * 8 + a / 65536);
        end procedure;

        -- CTRL, and the reference with it (both take it at the same edge)
        procedure set_ctrl(val : natural) is
        begin
            cpu_addr <= std_logic_vector(to_unsigned(16#48#, 10));
            cpu_din  <= std_logic_vector(to_unsigned(val, 8));
            vic_cs   <= '1';
            cpu_wr   <= '1';
            wait until rising_edge(clk);
            ref_ctrl <= std_logic_vector(to_unsigned(val mod 32, 8));
            cpu_wr   <= '0';
            vic_cs   <= '0';
            idle(7);
        end procedure;

        -- one byte of layer n's setup through port 1, which must point at it
        procedure set_byte(n, off : natural; val : natural; g : natural := 8) is
        begin
            cpu_addr <= std_logic_vector(to_unsigned(16#53#, 10));
            cpu_din  <= std_logic_vector(to_unsigned(val mod 256, 8));
            vic_cs   <= '1';
            cpu_wr   <= '1';
            wait until rising_edge(clk);
            ref_set(n)(off) <= std_logic_vector(to_unsigned(val mod 256, 8));
            cpu_wr   <= '0';
            vic_cs   <= '0';
            idle(g - 1);
        end procedure;

        procedure set_layer(n, mode : natural; map_sz : natural := 0; base : natural := 0;
                            tbase : natural := 0; sx : natural := 0; sy : natural := 0;
                            stride : natural := 0; bank : natural := 0) is
        begin
            port_set(1, 16#20800# + 32 * n);
            set_byte(n, 0, mode);
            set_byte(n, 1, map_sz);
            set_byte(n, 2, base mod 256);
            set_byte(n, 3, (base / 256) mod 256);
            set_byte(n, 4, base / 65536);
            set_byte(n, 5, tbase mod 256);
            set_byte(n, 6, (tbase / 256) mod 256);
            set_byte(n, 7, tbase / 65536);
            set_byte(n, 8, sx mod 256);
            set_byte(n, 9, sx / 256);
            set_byte(n, 10, sy mod 256);
            set_byte(n, 11, sy / 256);
            set_byte(n, 12, stride mod 256);
            set_byte(n, 13, stride / 256);
            set_byte(n, 14, bank);
        end procedure;

        -- scroll X of layer n, two bytes
        procedure set_sx(n, sx : natural) is
        begin
            port_set(1, 16#20808# + 32 * n);
            set_byte(n, 8, sx mod 256);
            set_byte(n, 9, sx / 256);
        end procedure;

        procedure set_order(val : natural) is
        begin
            port_set(1, 16#20840#);
            cpu_addr <= std_logic_vector(to_unsigned(16#53#, 10));
            cpu_din  <= std_logic_vector(to_unsigned(val, 8));
            vic_cs   <= '1';
            cpu_wr   <= '1';
            wait until rising_edge(clk);
            ref_order <= std_logic_vector(to_unsigned(val, 8));
            cpu_wr   <= '0';
            vic_cs   <= '0';
            idle(7);
        end procedure;

        procedure wait_frame is
        begin
            wait until rising_edge(clk) and frame_st = '1';
        end procedure;

        procedure wait_line(l : natural) is
        begin
            wait until rising_edge(clk) and line_st = '1' and
                       to_integer(unsigned(raster_y)) = l;
        end procedure;

        -- C64-speed traffic on the ports while the display runs: port 0
        -- writes VRAM the frame does not show, port 1 reads and checks
        procedure traffic(n : natural) is
        begin
            port_set(0, wr_a);
            port_set(1, rd_a);
            for i in 1 to n loop
                cpu_addr <= std_logic_vector(to_unsigned(16#4F#, 10));
                cpu_din  <= vram_byte(wr_a + 1);    -- a different value
                vic_cs   <= '1';
                cpu_wr   <= '1';
                wait until rising_edge(clk);
                ref_vram(wr_a) <= vram_byte(wr_a + 1);
                cpu_wr   <= '0';
                vic_cs   <= '0';
                wr_a := wr_a + 1;
                idle(63);
                rd(16#D053#, v, 64);
                if v /= ref_vram(rd_a) then
                    report "FAIL: port 1 at $" & hex(std_logic_vector(to_unsigned(rd_a, 20))) &
                           " read $" & hex(v) & ", want $" & hex(ref_vram(rd_a)) severity error;
                    errors := errors + 1;
                end if;
                rd_a := rd_a + 1;
            end loop;
        end procedure;

        procedure frame_check(what : string) is
            variable e0, c0, s0 : natural;
        begin
            wait_frame;
            e0 := vid_err; c0 := compared; s0 := shown;
            wait_frame;
            report what & ": " & integer'image(compared - c0) & " pixels, " &
                   integer'image(shown - s0) & " from the layer, " &
                   integer'image(vid_err - e0) & " wrong";
        end procedure;

    begin
        reset <= '1';
        idle(4);
        reset <= '0';
        idle(2600);                          -- the register-space clear
        wr(16#D06F#, 16#56#); wr(16#D06F#, 16#58#); wr(16#D06F#, 16#21#);

        -- CAP_FEAT
        rd(16#D047#, v);
        if v /= x"03" then
            report "FAIL: CAP_FEAT $" & hex(v) & ", want $03" severity error;
            errors := errors + 1;
        end if;

        -- VRAM: the block RAM is filled through port 0; external VRAM is
        -- the model's, which starts with the same contents
        if not EXT then
            port_set(0, 0);
            for a in 0 to 131071 loop
                wr(16#D04F#, to_integer(unsigned(vram_byte(a))), 1);
            end loop;
        end if;

        -- the palette: all 256 entries
        port_set(0, 16#20000#);
        for i in 0 to 255 loop
            wr(16#D04F#, to_integer(unsigned(pal_val(i)(23 downto 16))), 2);
            wr(16#D04F#, to_integer(unsigned(pal_val(i)(15 downto 8))), 2);
            wr(16#D04F#, to_integer(unsigned(pal_val(i)(7 downto 0))), 2);
            wr(16#D04F#, 0, 2);
            ref_pal(i) <= pal_val(i);
        end loop;

        checking <= true;

        -- map sizes: bits 0-1 width, 2-3 height, codes 32/64/128/256
        -- 8-bit 8x8 tiles, a 128x32 map, scrolled (as the parallax demo)
        set_layer(0, 16#01#, 16#02#, 16#00000#, 16#02000#, 5, 3);
        set_ctrl(16#11#);
        frame_check("tiles 8-bit 8x8, layer 0");

        -- and layer 1 behind it, another map, its own scroll
        set_layer(1, 16#01#, 16#00#, 16#04000#, 16#06000#, 1000, 77);
        set_ctrl(16#13#);
        frame_check("two 8-bit 8x8 tile layers");

        -- the order: layer 1 in front of everything; VIC-II on top; mixed
        set_order(16#0C#);
        frame_check("order $0C");
        set_order(16#13#);
        frame_check("order $13");
        set_order(16#24#);
        frame_check("order $24");
        set_order(16#07#);
        frame_check("order $07");

        -- 4-bit 16x16 tiles with flips and banks, a 64x256 map scrolled
        -- across its wrap; layer 1 8-bit 16x16, double width, 256x32
        set_order(16#00#);
        set_layer(0, 16#04#, 16#0D#, 16#08000#, 16#10000#, 64 * 16 - 5, 4090);
        set_layer(1, 16#0D#, 16#03#, 16#0C000#, 16#18000#, 4000, 0);
        frame_check("16x16 tiles 4-bit and 8-bit double width, wrapping");

        -- unaligned tile data, and a 4-bit bitmap in bank 3 on layer 1
        set_layer(0, 16#01#, 16#05#, 16#00010#, 16#0A003#, 333, 1234);
        set_layer(1, 16#02#, 0, 16#12345#, 0, 0, 0, 160, 3);
        frame_check("tile data at an odd address, 4-bit bitmap");

        -- 8-bit bitmap, double width, and 4-bit 8x8 tiles double width
        set_layer(0, 16#0B#, 0, 16#01000#, 0, 0, 0, 320);
        set_layer(1, 16#08#, 16#0F#, 16#14000#, 16#1C000#, 2047, 2047);
        set_order(16#04#);
        frame_check("bitmap and 4-bit tiles, both double width");

        -- raster splits: scroll X of both layers every 20 lines, the order
        -- and CTRL changed mid-frame, port traffic all frame long
        set_layer(0, 16#01#, 16#02#, 16#00000#, 16#02000#, 0, 0);
        set_layer(1, 16#01#, 16#00#, 16#04000#, 16#06000#, 0, 0);
        set_order(16#00#);
        set_ctrl(16#13#);
        wait_frame;
        for k in 0 to 9 loop
            wait_line(51 + 20 * k);
            idle(300 + 37 * k);
            set_sx(0, 7 * k + 3);
            set_sx(1, 3 * k + 1);
            traffic(3);
        end loop;
        wait_line(150);
        idle(900);
        set_order(16#0C#);
        wait_line(200);
        idle(1200);
        set_ctrl(16#11#);
        wait_frame;

        checking <= false;
        idle(10);

        report "frames: " & integer'image(compared) & " pixels, " &
               integer'image(shown) & " from the layer, " & integer'image(vid_err) & " wrong, " &
               integer'image(lates) & " late";
        if EXT then
            report "external VRAM: " & integer'image(requests) & " requests, " &
                   integer'image(misses) & " port misses";
        end if;
        if vid_err > 0 then
            errors := errors + 1;
        end if;
        if lates > 0 then
            report "FAIL: " & integer'image(lates) & " pixels late" severity error;
            errors := errors + 1;
        end if;
        if misses > 0 then
            report "FAIL: port reads found no data ready" severity error;
            errors := errors + 1;
        end if;
        if shown < 200000 then
            report "FAIL: too few layer pixels shown" severity error;
            errors := errors + 1;
        end if;
        if errors = 0 then
            report "PASS: VIC-X step 3";
        else
            report "FAILED: VIC-X step 3, " & integer'image(errors) & " failures" severity error;
        end if;
        done <= true;
        wait for 100 ns;
        if errors = 0 then
            finish(0);
        else
            finish(1);
        end if;
        wait;
    end process;

end architecture;
