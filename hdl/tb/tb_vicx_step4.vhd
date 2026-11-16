-- Testbench for VIC-X step 4: the sprite engine.  Built on the step 3
-- testbench (two layers, the order, border pixels in the window); the
-- reference adds sprite_line and the sprite places in mix_line from the
-- VICE fork (src/vicx/vicx.c), with the table latched each frame, and after
-- each frame the collision list, the status byte and IRQ_STAT bit 0 are
-- read back and compared (conformance tests t21-t24).
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

entity tb_vicx_step4 is
    generic (
        EXT  : boolean := false;    -- VRAM through the vx_* port
        REU  : boolean := false;    -- REU DMA holds the DMA0 slot (EXT only)
        WX   : natural := 120       -- first window pixel in the line
    );
end entity;

architecture sim of tb_vicx_step4 is

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
    type spr_t  is array (0 to 1023) of natural range 0 to 255;
    type pairs_t is array (0 to 126) of natural range 0 to 65535;
    signal ref_spr   : spr_t := (others => 0);
    -- what the block should publish after the window (from the reference)
    signal pub_n     : natural := 0;
    signal pub_pairs : pairs_t := (others => 0);
    signal pub_stat  : natural := 0;
    signal pub_frames : natural := 0;
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
        generic map (VRAM_BITS => 17, CAP_SPR => 128, CAP_SPRLINE => 32, CAP_FEAT => x"07",
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
    -- at a slot's start is acknowledged in the next clock; read data come 4
    -- clocks after that (sdram_vicx.vhd: ack at e2, rvalid at e10).

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
                    if tq(k) = 4 then
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
        -- sources: 0 VIC-II, 1 layer 0, 2 layer 1, 3 sprites, 4 sprites behind
        type src_arr is array (0 to 4) of natural;
        variable seq        : src_arr;
        variable nseq       : natural;
        variable pri        : src_arr;
        variable ord4       : src_arr;
        variable t          : natural;
        variable lp         : src_arr;
        variable done_px    : boolean;
        variable pend       : boolean;
        type line_t is array (0 to 319) of natural range 0 to 255;
        type occ_t  is array (0 to 319) of std_logic_vector(31 downto 0);
        variable sfront, sbehind : line_t := (others => 0);
        variable occ        : occ_t;
        variable tbl        : spr_t := (others => 0);
        type seen_t is array (0 to 16383) of boolean;
        variable seen       : seen_t := (others => false);
        variable cpairs     : pairs_t := (others => 0);
        variable ccount     : natural := 0;
        variable cstat      : natural := 0;
        variable sel_entry, sel_mem, sel_hit : spr_t;
        variable nsel, pix_n, any_ovl : natural;
        variable e, hh, ww, sw, row, rb, ra, sx0, sxx, ppx, cc, bk : natural;
        variable dwv, b8 : boolean;
        variable o32        : std_logic_vector(31 downto 0);
        variable nfr        : natural := 0;

        procedure coll_add(e1, e2 : natural) is
        begin
            if seen(e1 * 128 + e2) then
                return;
            end if;
            seen(e1 * 128 + e2) := true;
            if ccount >= 127 then
                if cstat mod 4 < 2 then cstat := cstat + 2; end if;   -- list full
                return;
            end if;
            cpairs(ccount) := e1 * 256 + e2;
            ccount := ccount + 1;
        end procedure;

        -- sprite_line for window line yy: front, behind, collisions
        procedure sprite_line(yy : natural) is
            variable base : natural;
            variable stop : boolean := false;
        begin
            sfront := (others => 0);
            sbehind := (others => 0);
            occ := (others => (others => '0'));
            nsel := 0; pix_n := 0;
            for en in 0 to 127 loop
                if not stop then
                    base := en * 8;
                    if (tbl(base + 3) / 4) mod 2 = 1 then
                        hh := 8 * 2 ** ((tbl(base + 1) / 16) mod 4);
                        row := (yy + 1024 - (tbl(base + 2) + 256 * (tbl(base + 3) mod 4))) mod 1024;
                        if row < hh then
                            ww := 8 * 2 ** ((tbl(base + 1) / 4) mod 4);
                            dwv := (tbl(base + 6) / 32) mod 2 = 1;
                            if dwv then sw := 2 * ww; else sw := ww; end if;
                            if nsel >= 32 or pix_n + sw > 640 then
                                if cstat mod 2 = 0 then cstat := cstat + 1; end if;   -- overflow
                                stop := true;
                            else
                                pix_n := pix_n + sw;
                                if (tbl(base + 1) / 128) mod 2 = 1 then row := hh - 1 - row; end if;
                                b8 := (tbl(base + 6) / 16) mod 2 = 1;
                                if b8 then rb := ww; else rb := ww / 2; end if;
                                ra := (tbl(base + 4) + 256 * tbl(base + 5)) * 32 + row * rb;
                                bk := (tbl(base + 6) mod 16) * 16;
                                sx0 := tbl(base) + 256 * (tbl(base + 1) mod 4);
                                for i in 0 to sw - 1 loop
                                    sxx := (sx0 + i) mod 1024;
                                    if sxx < 320 then
                                        if dwv then ppx := i / 2; else ppx := i; end if;
                                        if (tbl(base + 1) / 64) mod 2 = 1 then ppx := ww - 1 - ppx; end if;
                                        if b8 then
                                            cc := to_integer(unsigned(ref_vram((ra + ppx) mod 131072)));
                                        else
                                            cc := to_integer(unsigned(ref_vram((ra + ppx / 2) mod 131072)));
                                            if ppx mod 2 = 0 then cc := cc / 16; else cc := cc mod 16; end if;
                                            if cc /= 0 then cc := bk + cc; end if;
                                        end if;
                                        if cc /= 0 then
                                            if (tbl(base + 3) / 8) mod 2 = 1 then
                                                if sbehind(sxx) = 0 then sbehind(sxx) := cc; end if;
                                            else
                                                if sfront(sxx) = 0 then sfront(sxx) := cc; end if;
                                            end if;
                                            occ(sxx)(nsel) := '1';
                                        end if;
                                    end if;
                                end loop;
                                sel_entry(nsel) := en;
                                sel_mem(nsel) := tbl(base + 3) / 16;
                                if tbl(base + 7) mod 16 /= 0 then
                                    sel_hit(nsel) := tbl(base + 7) mod 16;
                                else
                                    sel_hit(nsel) := sel_mem(nsel);
                                end if;
                                nsel := nsel + 1;
                            end if;
                        end if;
                    end if;
                end if;
            end loop;
            -- collisions, in pixel order
            for xx in 0 to 319 loop
                o32 := occ(xx);
                if (o32 and std_logic_vector(unsigned(o32) - 1)) /= x"00000000" then
                    for i in 0 to 31 loop
                        if i < nsel and o32(i) = '1' then
                            for j in i + 1 to 31 loop
                                if j < nsel and o32(j) = '1' and
                                   ((to_unsigned(sel_mem(i), 4) and to_unsigned(sel_hit(j), 4)) /= "0000" or
                                    (to_unsigned(sel_mem(j), 4) and to_unsigned(sel_hit(i), 4)) /= "0000") then
                                    coll_add(sel_entry(i), sel_entry(j));
                                end if;
                            end loop;
                        end if;
                    end loop;
                end if;
            end loop;
        end procedure;

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

        if frame_st = '1' then
            tbl := ref_spr;                     -- latched with the block
        end if;
        if line_st = '1' then
            ctl  := ref_ctrl;
            st   := ref_set;
            ordr := ref_order;
            -- the order for this line (mix_line): stable sort, high
            -- priority first, ties sprites, VIC-II, layer 0, layer 1; the
            -- behind sprites right after the source that follows the sprites
            pri(3) := u8(ordr(7 downto 6));
            pri(0) := u8(ordr(5 downto 4));
            pri(1) := u8(ordr(1 downto 0));
            pri(2) := u8(ordr(3 downto 2));
            ord4 := (3, 0, 1, 2, 0);
            for a in 1 to 3 loop
                for c in 3 downto 1 loop
                    if pri(ord4(c)) > pri(ord4(c - 1)) then
                        t := ord4(c); ord4(c) := ord4(c - 1); ord4(c - 1) := t;
                    end if;
                end loop;
            end loop;
            nseq := 0; pend := false;
            for k in 0 to 3 loop
                seq(nseq) := ord4(k); nseq := nseq + 1;
                if ord4(k) = 3 then
                    pend := true;
                elsif pend then
                    seq(nseq) := 4; nseq := nseq + 1; pend := false;
                end if;
            end loop;
            if pend then
                seq(nseq) := 4; nseq := nseq + 1;
            end if;
            -- this line's sprites
            sfront := (others => 0);
            sbehind := (others => 0);
            if to_integer(unsigned(raster_y)) >= 51 and to_integer(unsigned(raster_y)) < 251 and
               ctl(2) = '1' then
                sprite_line(to_integer(unsigned(raster_y)) - 51);
            end if;
            -- after the window's last line: what the block publishes
            if to_integer(unsigned(raster_y)) = 251 then
                pub_n     <= ccount;
                pub_pairs <= cpairs;
                pub_stat  <= cstat;
                nfr := nfr + 1;
                pub_frames <= nfr;
                ccount := 0;
                cstat  := 0;
                seen   := (others => false);
            end if;
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
                lp(3) := sfront(x);
                lp(4) := sbehind(x);
                done_px := false;
                for k in 0 to 4 loop
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

        -- one sprite table entry through port 1
        procedure set_spr(en : natural; sx, sy : natural; wcode, hcode : natural;
                          flips : natural := 0; shown_on : boolean := true; behind : boolean := false;
                          groups : natural := 0; ptr : natural := 0; bank : natural := 0;
                          b8 : boolean := false; dw : boolean := false; hits : natural := 0) is
            type b8_t is array (0 to 7) of natural;
            variable b : b8_t;
        begin
            b(0) := sx mod 256;
            b(1) := (sx / 256) mod 4 + 4 * wcode + 16 * hcode + 64 * flips;
            b(2) := sy mod 256;
            b(3) := (sy / 256) mod 4 + 16 * groups;
            if shown_on then b(3) := b(3) + 4; end if;
            if behind then b(3) := b(3) + 8; end if;
            b(4) := ptr mod 256;
            b(5) := ptr / 256;
            b(6) := bank;
            if b8 then b(6) := b(6) + 16; end if;
            if dw then b(6) := b(6) + 32; end if;
            b(7) := hits;
            port_set(1, 16#20400# + 8 * en);
            for k in 0 to 7 loop
                cpu_addr <= std_logic_vector(to_unsigned(16#53#, 10));
                cpu_din  <= std_logic_vector(to_unsigned(b(k), 8));
                vic_cs   <= '1';
                cpu_wr   <= '1';
                wait until rising_edge(clk);
                ref_spr(8 * en + k) <= b(k);
                cpu_wr   <= '0';
                vic_cs   <= '0';
                idle(3);
            end loop;
        end procedure;

        -- after a frame: the published list, status and IRQ against the reference
        procedure check_coll(what : string; pairs_too : boolean := true) is
            variable v2 : std_logic_vector(7 downto 0);
            variable bad : natural := 0;
        begin
            wait until rising_edge(clk) and line_st = '1' and to_integer(unsigned(raster_y)) = 270;
            port_set(1, 16#20841#);
            rd(16#D053#, v2);
            if to_integer(unsigned(v2)) /= pub_stat then
                report "FAIL: " & what & ": status $" & hex(v2) & ", want " & integer'image(pub_stat) severity error;
                bad := bad + 1;
            end if;
            port_set(1, 16#20900#);
            rd(16#D053#, v2);
            if to_integer(unsigned(v2)) /= pub_n then
                report "FAIL: " & what & ": " & integer'image(to_integer(unsigned(v2))) & " pairs, want " &
                       integer'image(pub_n) severity error;
                bad := bad + 1;
            else
                for k in 0 to pub_n - 1 loop
                    rd(16#D053#, v2);
                    if to_integer(unsigned(v2)) /= pub_pairs(k) / 256 then bad := bad + 1; end if;
                    rd(16#D053#, v2);
                    if to_integer(unsigned(v2)) /= pub_pairs(k) mod 256 then bad := bad + 1; end if;
                end loop;
                if bad > 0 and pairs_too then
                    report "FAIL: " & what & ": the pairs differ" severity error;
                elsif not pairs_too then
                    bad := 0;
                end if;
            end if;
            rd(16#D04A#, v2);
            if (v2(0) = '1') /= (pub_n > 0) then
                report "FAIL: " & what & ": IRQ_STAT $" & hex(v2) severity error;
                bad := bad + 1;
            end if;
            wr(16#D04A#, 16#07#);
            report what & ": " & integer'image(pub_n) & " pairs, status " & integer'image(pub_stat);
            if bad > 0 then
                errors := errors + 1;
            end if;
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
        if v /= x"07" then
            report "FAIL: CAP_FEAT $" & hex(v) & ", want $07" severity error;
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

        -- layer 0: an 8-bit bitmap, layer 1: 8x8 tiles; sprites on top
        set_layer(0, 16#03#, 0, 16#00000#, 0, 0, 0, 320);
        set_layer(1, 16#01#, 16#00#, 16#04000#, 16#06000#, 10, 20);
        set_order(16#00#);
        -- 24 sprites: every size, flips, 4- and 8-bit, double width,
        -- wrapping at X 1020 and Y 1020, groups that meet
        for k in 0 to 23 loop
            set_spr(k * 5, (k * 53 + 1020 * (k mod 7 / 6)) mod 1024, (k * 37 + 1010 * (k mod 9 / 8)) mod 1024,
                    k mod 4, (k / 4) mod 4, k mod 4, true, k mod 5 = 0, 1 + k mod 3,
                    (k * 211) mod 4096, k mod 16, k mod 2 = 0, k mod 3 = 0, (k / 3) mod 4);
        end loop;
        set_ctrl(16#17#);
        frame_check("24 sprites over two layers");
        check_coll("24 sprites");

        -- the order: sprites behind the VIC-II, between the layers, at the back
        set_order(16#24#);
        frame_check("order $24");
        set_order(16#C3#);
        frame_check("order $C3");
        set_order(16#0C#);
        frame_check("order $0C");

        -- sprites off: nothing drawn, nothing collides
        set_order(16#00#);
        set_ctrl(16#13#);
        frame_check("sprites off");
        check_coll("sprites off");

        -- too many on one line: 40 8x8 sprites from entry 30, then wide ones
        for k in 0 to 39 loop
            set_spr(30 + k, k * 8, 100 + k mod 4, 0, 0, groups => 0, ptr => k * 3);
        end loop;
        set_ctrl(16#17#);
        frame_check("40 sprites on a line");
        check_coll("40 sprites on a line");
        for k in 0 to 39 loop
            set_spr(30 + k, k * 8, 100, 3, 0, shown_on => k < 11, ptr => k * 3, b8 => true);
        end loop;
        frame_check("11 sprites of 64 pixels");
        check_coll("11 sprites of 64 pixels");

        -- a small heap: 6 sprites on top of each other, groups that meet
        for k in 0 to 39 loop
            set_spr(30 + k, 0, 0, 0, 0, shown_on => false);
        end loop;
        for k in 0 to 5 loop
            set_spr(80 + k, 100 + 3 * k, 60 + 2 * k, 1, 1, groups => 1 + k mod 2, hits => 3,
                    ptr => 400 + k, b8 => true);
        end loop;
        frame_check("6 sprites in a heap");
        check_coll("6 sprites in a heap");

        -- a big heap: 20 in one group, more pairs than the list holds.  The
        -- hardware checks pairs at one a clock as the pixels show, so with
        -- this many at one pixel it falls behind and the list holds other
        -- pairs than VICE's; the count and the full flag must still agree
        for k in 0 to 19 loop
            set_spr(80 + k, 100 + k, 60 + k, 1, 1, groups => 1, ptr => 400 + k, b8 => true);
        end loop;
        frame_check("20 sprites in a heap");
        check_coll("20 sprites in a heap", pairs_too => false);

        -- the table is latched per frame: changes in mid-frame wait
        wait_frame;
        wait_line(120);
        for k in 0 to 9 loop
            set_spr(80 + k, 30 * k, 150, 2, 2, groups => 2, hits => 1, ptr => 600 + k);
        end loop;
        traffic(20);
        wait_frame;
        frame_check("moved in mid-frame");
        check_coll("moved in mid-frame");

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
        if shown < 300000 then
            report "FAIL: too few layer pixels shown" severity error;
            errors := errors + 1;
        end if;
        if errors = 0 then
            report "PASS: VIC-X step 4";
        else
            report "FAILED: VIC-X step 4, " & integer'image(errors) & " failures" severity error;
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
