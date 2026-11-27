-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Michael Hartman
--
-- Testbench for the VIC-X DMA engine (step 5, external VRAM only).  VRAM,
-- C64 RAM and XRAM (2 MB) sit behind a model of the SDRAM controller's VIC-X
-- port; every transfer is also run on a reference that follows the VICE
-- fork's dma_run (src/vicx/vicx.c), and the memories are compared after it.
-- Covers copy, fill, masked copy, expand and masked expand (CAP_BLIT bit 0),
-- remap (bit 1), scaled copy (bit 2), mirror and backwards (bit 3) with
-- signed strides, lists in VRAM (bit 4),
-- straight and 2D, chains with the IRQ,
-- the register space (palette entries 0-15 and above), XRAM wrapping,
-- overlapping copies, reserved operations, starts while busy, the CPU halt,
-- and a port's copy seeing a DMA write.
-- Run with hdl/run_sim.sh; prints PASS or the failures and exits 1.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.vicx_pkg.all;

entity tb_vicx_dma is
end entity;

architecture sim of tb_vicx_dma is

    constant C64_SZ  : natural := 65536;
    constant VRAM_SZ : natural := 131072;
    constant XRAM_SZ : natural := 2 * 1048576;
    constant REGS_SZ : natural := 16#A00#;

    type mem_pt is protected
        procedure init(seed : natural);
        impure function get(sp : natural; a : natural) return natural;
        procedure put(sp : natural; a : natural; v : natural);
    end protected;

    type mem_pt is protected body
        type c64_t  is array (0 to C64_SZ - 1) of natural range 0 to 255;
        type vram_t is array (0 to VRAM_SZ - 1) of natural range 0 to 255;
        type xram_t is array (0 to XRAM_SZ - 1) of natural range 0 to 255;
        type regs_t is array (0 to REGS_SZ - 1) of natural range 0 to 255;
        variable c64  : c64_t;
        variable vram : vram_t;
        variable xram : xram_t;
        variable regs : regs_t := (others => 0);

        procedure init(seed : natural) is
        begin
            for a in c64'range loop c64(a) := (a * 31 + a / 256 * 7 + seed) mod 256; end loop;
            for a in vram'range loop vram(a) := (a * 57 + a / 512 * 13 + seed) mod 256; end loop;
            for a in xram'range loop xram(a) := (a * 89 + a / 1024 * 3 + seed) mod 256; end loop;
            for i in 0 to 15 loop                   -- the stock palette, as the block shows it
                regs(i * 4)     := i * 16;
                regs(i * 4 + 1) := i * 16 + 1;
                regs(i * 4 + 2) := i * 16 + 2;
                regs(i * 4 + 3) := 0;
            end loop;
        end procedure;

        -- sp: 0 C64, 1 VRAM, 2 XRAM, 3 register space (offset from $20000)
        impure function get(sp : natural; a : natural) return natural is
        begin
            case sp is
                when 0 => return c64(a);
                when 1 => return vram(a);
                when 2 => return xram(a);
                when others => return regs(a);
            end case;
        end function;

        procedure put(sp : natural; a : natural; v : natural) is
        begin
            case sp is
                when 0 => c64(a) := v;
                when 1 => vram(a) := v;
                when 2 => xram(a) := v;
                when others => regs(a) := v;
            end case;
        end procedure;
    end protected body;

    shared variable model : mem_pt;     -- what the memory model holds
    shared variable ref   : mem_pt;     -- what it should hold

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
    signal rgb_out   : std_logic_vector(23 downto 0);
    signal cpu_halt  : std_logic;
    signal bus_addr  : std_logic_vector(15 downto 0) := (others => '0');
    signal win_hit   : std_logic;
    signal win_addr  : std_logic_vector(24 downto 0);

    signal vx_req, vx_we, vx_ack, vx_rvalid, vx_miss : std_logic := '0';
    signal vx_addr   : std_logic_vector(24 downto 0);
    signal vx_din    : std_logic_vector(15 downto 0);
    signal vx_be     : std_logic_vector(1 downto 0);
    signal vx_rdata  : std_logic_vector(63 downto 0) := (others => '0');
    signal ready     : boolean := false;
    signal done      : boolean := false;
    signal bad_addr  : natural := 0;
    signal line_st   : std_logic := '0';
    signal raster_y  : std_logic_vector(8 downto 0) := (others => '0');

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

    function h(n : natural; digits : natural := 6) return string is
    begin
        return hex(std_logic_vector(to_unsigned(n, 4 * digits)));
    end function;

begin

    clk <= not clk after 5 ns when not done;

    stock_init : for i in 0 to 15 generate
        stock(i) <= std_logic_vector(to_unsigned(i * 16, 8)) &
                    std_logic_vector(to_unsigned(i * 16 + 1, 8)) &
                    std_logic_vector(to_unsigned(i * 16 + 2, 8));
    end generate;

    dut : entity work.vicx
        generic map (VRAM_BITS => 17, CAP_SPR => 0, CAP_SPRLINE => 0, CAP_FEAT => x"0A", CAP_BLIT => x"1F",
                     EXT_VRAM => true)
        port map (
            clk => clk, reset => reset,
            vic_cs => vic_cs, cpu_addr => cpu_addr, cpu_din => cpu_din,
            cpu_wr => cpu_wr, cpu_rd => cpu_rd, claim => claim,
            cpu_dout => cpu_dout, irq => irq,
            xram_mb => x"02", stock_rgb => stock,
            frame_start => '0', line_start => line_st, raster_y => raster_y,
            vic_idx => x"0", vic_rgb => x"000000", rgb_out => rgb_out,
            vx_req => vx_req, vx_we => vx_we, vx_addr => vx_addr, vx_din => vx_din,
            vx_be => vx_be, vx_ack => vx_ack, vx_rdata => vx_rdata,
            vx_rvalid => vx_rvalid, vx_miss => vx_miss, cpu_halt => cpu_halt,
            bus_addr => bus_addr, win_hit => win_hit, win_addr => win_addr);

    -- the SDRAM controller's VIC-X port (see tb_vicx_step2), over the three
    -- spaces at their SDRAM addresses
    mem_model : process (clk)
        variable cnt   : natural := 0;
        type tq_t is array (0 to 3) of integer;
        type bq_t is array (0 to 3) of std_logic_vector(63 downto 0);
        variable tq    : tq_t := (others => -1);   -- reads in flight: clocks since taken
        variable bq    : bq_t;
        variable a, sp, o : natural;
        variable slot  : natural;
        variable blk   : std_logic_vector(63 downto 0);

        procedure locate(ad : natural; s : out natural; off : out natural) is
        begin
            if ad < C64_SZ then
                s := 0; off := ad;
            elsif ad >= 16#100000# and ad < 16#100000# + VRAM_SZ then
                s := 1; off := ad - 16#100000#;
            elsif ad >= 16#1000000# and ad < 16#1000000# + XRAM_SZ then
                s := 2; off := ad - 16#1000000#;
            else
                s := 9; off := 0;
            end if;
        end procedure;
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
            if cnt mod 4 = 0 and vx_req = '1' and
               (slot = 1 or slot = 4 or slot = 5 or slot = 6) then
                a := to_integer(unsigned(vx_addr));
                vx_ack <= '1';
                if vx_we = '1' then
                    for ln in 0 to 1 loop
                        if vx_be(ln) = '1' then
                            locate((a / 2) * 2 + ln, sp, o);
                            if sp = 9 then
                                bad_addr <= bad_addr + 1;
                            else
                                model.put(sp, o, to_integer(unsigned(vx_din(8 * ln + 7 downto 8 * ln))));
                            end if;
                        end if;
                    end loop;
                else
                    for n in 0 to 7 loop
                        locate((a / 8) * 8 + n, sp, o);
                        if sp = 9 then
                            bad_addr <= bad_addr + 1;
                            blk(8 * n + 7 downto 8 * n) := x"EE";
                        else
                            blk(8 * n + 7 downto 8 * n) := std_logic_vector(to_unsigned(model.get(sp, o), 8));
                        end if;
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

    -- raster lines (63 cycles of 32 clocks), so a layer fetches while DMA runs
    lines : process
        variable ln : natural := 0;
    begin
        for i in 1 to 2015 loop
            wait until rising_edge(clk);
        end loop;
        line_st  <= '1';
        raster_y <= std_logic_vector(to_unsigned(ln, 9));
        wait until rising_edge(clk);
        line_st <= '0';
        ln := (ln + 1) mod 312;
    end process;

    stim : process
        variable errors : natural := 0;
        variable v      : std_logic_vector(7 downto 0);
        variable halted : boolean;
        type desc_t is array (0 to 31) of natural;
        variable d      : desc_t;

        procedure idle(n : natural) is
        begin
            for i in 1 to n loop
                wait until rising_edge(clk);
            end loop;
        end procedure;

        procedure fail(msg : string) is
        begin
            report "FAIL: " & msg severity error;
            errors := errors + 1;
        end procedure;

        procedure wr(addr : natural; val : natural; g : natural := 8) is
        begin
            cpu_addr <= std_logic_vector(to_unsigned(addr mod 1024, 10));
            cpu_din  <= std_logic_vector(to_unsigned(val mod 256, 8));
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

        -- the reference's view of a DMA space (VICE dma_read / dma_write)
        impure function ref_rd(sp : natural; a : natural) return natural is
            variable pa : natural;
        begin
            case sp is
                when 0 => return ref.get(0, a mod C64_SZ);
                when 1 =>
                    pa := a mod 262144;
                    if pa < VRAM_SZ then
                        return ref.get(1, pa);
                    elsif pa >= 16#20000# and pa < 16#20000# + REGS_SZ then
                        return ref.get(3, pa - 16#20000#);
                    end if;
                    return 255;
                when 2 => return ref.get(2, (a mod 16777216) mod XRAM_SZ);
                when others => return 255;
            end case;
        end function;

        procedure ref_wr(sp : natural; a : natural; val : natural) is
            variable pa : natural;
        begin
            case sp is
                when 0 => ref.put(0, a mod C64_SZ, val);
                when 1 =>
                    pa := a mod 262144;
                    if pa < VRAM_SZ then
                        ref.put(1, pa, val);
                    elsif pa >= 16#20000# and pa < 16#20000# + REGS_SZ then
                        ref.put(3, pa - 16#20000#, val);
                    end if;
                when 2 => ref.put(2, (a mod 16777216) mod XRAM_SZ, val);
                when others => null;
            end case;
        end procedure;

        -- a register-space write through port 1, kept in the reference
        procedure reg_store(a : natural; val : natural) is
        begin
            port_set(1, 16#20000# + a);
            wr(16#D053#, val);
            ref.put(3, a, val mod 256);
        end procedure;

        -- descriptor n with these fields, written through the port
        procedure desc(n : natural; op, spaces : natural; src, dst : natural;
                       w : natural; hgt : natural := 0; ss : natural := 0; ds : natural := 0;
                       fill : natural := 0; tr : natural := 0; nxt : natural := 255;
                       tbl : natural := 0; xs : natural := 0; ys : natural := 0) is
            variable b : desc_t := (others => 0);
        begin
            b(0) := op; b(1) := spaces;
            for k in 0 to 3 loop
                b(2 + k) := (src / (256 ** k)) mod 256;
                b(6 + k) := (dst / (256 ** k)) mod 256;
            end loop;
            b(10) := w mod 256;   b(11) := w / 256;
            b(12) := hgt mod 256; b(13) := hgt / 256;
            b(14) := ss mod 256;  b(15) := ss / 256;
            b(16) := ds mod 256;  b(17) := ds / 256;
            b(18) := fill; b(19) := tr; b(20) := nxt;
            b(21) := tbl mod 256; b(22) := (tbl / 256) mod 256; b(23) := (tbl / 65536) mod 256;
            b(24) := xs mod 256; b(25) := xs / 256; b(26) := ys mod 256; b(27) := ys / 256;
            port_set(1, 16#20880# + 32 * n);
            for k in 0 to 31 loop
                wr(16#D053#, b(k), 4);
                ref.put(3, 16#880# + 32 * n + k, b(k));
            end loop;
        end procedure;

        -- list entry k at base: as desc(), but into VRAM through port 1
        procedure lst(lb : natural; k : natural; op, spaces : natural; src, dst : natural;
                      w : natural; hgt : natural := 0; ss : natural := 0; ds : natural := 0;
                      fill : natural := 0; tr : natural := 0;
                      tbl : natural := 0; xs : natural := 0; ys : natural := 0) is
            variable b : desc_t := (others => 0);
            variable a : natural;
        begin
            b(0) := op; b(1) := spaces;
            for j in 0 to 3 loop
                b(2 + j) := (src / (256 ** j)) mod 256;
                b(6 + j) := (dst / (256 ** j)) mod 256;
            end loop;
            b(10) := w mod 256;   b(11) := w / 256;
            b(12) := hgt mod 256; b(13) := hgt / 256;
            b(14) := ss mod 256;  b(15) := ss / 256;
            b(16) := ds mod 256;  b(17) := ds / 256;
            b(18) := fill; b(19) := tr; b(20) := 255;
            b(21) := tbl mod 256; b(22) := (tbl / 256) mod 256; b(23) := (tbl / 65536) mod 256;
            b(24) := xs mod 256; b(25) := xs / 256; b(26) := ys mod 256; b(27) := ys / 256;
            for j in 0 to 31 loop
                a := (lb + 32 * k + j) mod VRAM_SZ;
                port_set(1, a);
                wr(16#D053#, b(j), 4);
                ref.put(1, a, b(j));
            end loop;
        end procedure;

        procedure lst_end(lb : natural; k : natural) is
            variable a : natural;
        begin
            a := (lb + 32 * k) mod VRAM_SZ;
            port_set(1, a);
            wr(16#D053#, 255, 4);
            ref.put(1, a, 255);
        end procedure;

        procedure list_at(la : natural) is
        begin
            port_set(1, 16#2085C#);
            for j in 0 to 2 loop
                wr(16#D053#, (la / (256 ** j)) mod 256, 4);
                ref.put(3, 16#85C# + j, (la / (256 ** j)) mod 256);
            end loop;
        end procedure;

        -- run descriptor n (and its chain) on the reference, as dma_start does
        procedure ref_run(n0 : natural; irq_want : out boolean; list : boolean := false) is
            variable n, op, ssp, dsp, src, dst, w, hh, sst, dst2, fill, tr, nxt : natural;
            variable ran : std_logic_vector(3 downto 0) := "0000";
            variable twod : boolean;
            variable base : natural;
            variable val  : natural;
            variable s0, t0 : natural;
            variable ssi, dsi : integer;            -- strides, signed
            variable mir, bwd : boolean;
            variable r, i, di : natural;
            variable sxs, sys, sri : natural;       -- scaled: steps, source row
            variable bit1 : boolean;
            type tbl_t is array (0 to 255) of natural;
            variable tbl  : tbl_t;
            variable ta   : natural;
            variable dd   : desc_t;                 -- the descriptor being run
            variable la, lk : natural;              -- list: entry address, count
        begin
            irq_want := false;
            n := n0;
            la := ref.get(3, 16#85C#) + 256 * ref.get(3, 16#85D#) + 65536 * ref.get(3, 16#85E#);
            lk := 0;
            loop
                if list then
                    -- a list in VRAM: each entry read as its turn comes
                    exit when lk >= 4096;
                    for k in 0 to 31 loop
                        dd(k) := ref.get(1, (la + k) mod VRAM_SZ);
                    end loop;
                    exit when dd(0) = 255;
                else
                    exit when n >= 4;
                    exit when ran(n) = '1';
                    ran(n) := '1';
                    for k in 0 to 31 loop
                        dd(k) := ref.get(3, 16#880# + 32 * n + k);
                    end loop;
                end if;
                op  := dd(0);
                ssp := dd(1) mod 4;
                dsp := (dd(1) / 4) mod 4;
                twod := (dd(1) / 16) mod 2 = 1;
                if (dd(1) / 32) mod 2 = 1 then
                    irq_want := true;
                end if;
                src := dd(2) + 256 * dd(3) + 65536 * dd(4);
                dst := dd(6) + 256 * dd(7) + 65536 * dd(8);
                w   := dd(10) + 256 * dd(11);
                if twod then
                    hh := dd(12) + 256 * dd(13);
                else
                    hh := 1;
                end if;
                sst  := dd(14) + 256 * dd(15);
                dst2 := dd(16) + 256 * dd(17);
                fill := dd(18);
                tr   := dd(19);
                nxt  := dd(20);
                -- reserved: operations above 4, the direction bits (not built)
                if op = 5 then                  -- the table, as it starts
                    ta := dd(21) + 256 * dd(22) + 65536 * dd(23);
                    for k in 0 to 255 loop
                        tbl(k) := ref.get(1, (ta + k) mod VRAM_SZ);
                    end loop;
                end if;
                sxs := dd(24) + 256 * dd(25);
                sys := dd(26) + 256 * dd(27);
                if not (op > 6 or dsp = 3 or (op /= 1 and ssp = 3)) then
                    -- signed strides; mirror: byte i to w - 1 - i; backwards:
                    -- last row first, each row from its last byte
                    ssi := sst; dsi := dst2;
                    if ssi >= 32768 then ssi := ssi - 65536; end if;
                    if dsi >= 32768 then dsi := dsi - 65536; end if;
                    mir := (dd(1) / 64) mod 2 = 1;
                    bwd := dd(1) >= 128;
                    for rr in 0 to hh - 1 loop
                        if bwd then r := hh - 1 - rr; else r := rr; end if;
                        if op = 6 then sri := (r * sys) / 256; else sri := r; end if;
                        if twod then
                            s0 := (src + sri * ssi) mod 16777216; t0 := (dst + r * dsi) mod 16777216;
                        else
                            s0 := src; t0 := dst;
                        end if;
                        for ii in 0 to w - 1 loop
                            if bwd then i := w - 1 - ii; else i := ii; end if;
                            if mir then di := w - 1 - i; else di := i; end if;
                            if op = 1 then
                                ref_wr(dsp, t0 + di, fill);
                            elsif op = 3 or op = 4 then
                                -- expand: bit 7 - i mod 8 of source byte i / 8
                                val  := ref_rd(ssp, s0 + i / 8);
                                bit1 := (val / 2 ** (7 - i mod 8)) mod 2 = 1;
                                if bit1 then
                                    ref_wr(dsp, t0 + di, fill);
                                elsif op = 3 then
                                    ref_wr(dsp, t0 + di, tr);
                                end if;
                            else
                                if op = 6 then
                                    val := ref_rd(ssp, s0 + (i * sxs) / 256);
                                else
                                    val := ref_rd(ssp, s0 + i);
                                end if;
                                if op = 0 or val /= tr then
                                    if op = 5 then
                                        val := tbl(val);
                                    end if;
                                    ref_wr(dsp, t0 + di, val);
                                end if;
                            end if;
                        end loop;
                    end loop;
                end if;
                if list then
                    la := la + 32;
                    lk := lk + 1;
                elsif nxt = 255 then
                    n := 4;
                else
                    n := nxt;
                end if;
            end loop;
        end procedure;

        -- start the chain at n, wait for busy to clear, compare everything
        procedure run(n : natural; what : string; c64 : boolean := false;
                      check_regs : boolean := false; list : boolean := false) is
            variable irq_want : boolean;
            variable cycles   : natural := 0;
            variable bad      : natural := 0;
            variable g, w     : natural;
            variable irq_was  : std_logic_vector(7 downto 0);
        begin
            wr(16#D04A#, 16#07#);                       -- clear IRQ_STAT
            ref_run(n, irq_want, list);
            if list then
                wr(16#D05A#, 4 + n);                    -- bits 0-1 ignored
            else
                wr(16#D05A#, n);
            end if;
            halted := false;
            loop
                if cpu_halt = '1' then
                    halted := true;
                end if;
                wait until rising_edge(clk);
                cycles := cycles + 1;
                -- the CPU cannot read while held: poll only when free
                if cpu_halt = '0' and cycles mod 64 = 0 then
                    rd(16#D05A#, v);
                    exit when v(7) = '0';
                end if;
                if cycles > 4000000 then
                    fail(what & ": DMA never finished");
                    exit;
                end if;
            end loop;
            if c64 and not halted then
                fail(what & ": CPU not held during a C64 RAM transfer");
            elsif not c64 and halted then
                fail(what & ": CPU held during a background transfer");
            end if;
            -- queued writes go out: the DMA is done when its last words are
            -- in the port write queue, which can take hundreds of clocks
            -- to drain behind layer reads (software cannot see this: port
            -- reads go after queued writes). Wait for 400 clocks without a
            -- write request.
            w := 0;
            for i in 1 to 20000 loop
                wait until rising_edge(clk);
                if vx_req = '1' and vx_we = '1' then w := 0; else w := w + 1; end if;
                exit when w = 400;
            end loop;
            rd(16#D04A#, irq_was);
            if irq_want and irq_was(1) = '0' then
                fail(what & ": no DMA IRQ");
            elsif not irq_want and irq_was(1) = '1' then
                fail(what & ": DMA IRQ not asked for");
            end if;
            for sp in 0 to 2 loop
                case sp is
                    when 0 => w := C64_SZ;
                    when 1 => w := VRAM_SZ;
                    when others => w := XRAM_SZ;
                end case;
                for a in 0 to w - 1 loop
                    g := model.get(sp, a);
                    if g /= ref.get(sp, a) then
                        bad := bad + 1;
                        if bad <= 6 then
                            fail(what & ": space " & integer'image(sp) & " $" & h(a) &
                                 " is $" & h(g, 2) & ", want $" & h(ref.get(sp, a), 2));
                        end if;
                    end if;
                end loop;
            end loop;
            if check_regs then
                port_set(1, 16#20000#);
                for a in 0 to REGS_SZ - 1 loop
                    rd(16#D053#, v);
                    if to_integer(unsigned(v)) /= ref.get(3, a) then
                        bad := bad + 1;
                        if bad <= 6 then
                            fail(what & ": register $" & h(16#20000# + a, 5) & " is $" & hex(v) &
                                 ", want $" & h(ref.get(3, a), 2));
                        end if;
                    end if;
                end loop;
            end if;
            report what & ": " & integer'image(cycles) & " clocks, " &
                   integer'image(bad) & " wrong";
        end procedure;

    begin
        model.init(7);
        ref.init(7);
        reset <= '1';
        idle(4);
        reset <= '0';
        idle(2600);
        wr(16#D06F#, 16#56#); wr(16#D06F#, 16#58#); wr(16#D06F#, 16#21#);

        -- spaces: 0 C64, 1 VRAM, 2 XRAM; +1 = src + 4 * dst, +16 2D, +32 IRQ
        desc(0, 1, 1 * 4, 0, 16#01000#, 1000, fill => 16#5A#);
        run(0, "fill VRAM");

        desc(0, 0, 2 + 1 * 4, 16#012345#, 16#00FF3#, 3001);
        run(0, "copy XRAM to VRAM, unaligned");

        desc(1, 0, 1 + 2 * 4 + 16, 16#00100#, 16#100003#, 37, 9, 320, 40);
        run(1, "2D copy VRAM to XRAM");

        desc(2, 2, 0 + 1 * 4, 16#C000#, 16#04001#, 500, tr => 16#00#);
        for a in 16#C000# to 16#C000# + 499 loop       -- zeros to skip
            if a mod 3 = 0 then
                model.put(0, a, 0);
                ref.put(0, a, 0);
            end if;
        end loop;
        run(2, "masked copy C64 to VRAM", c64 => true);

        desc(3, 0, 1 + 1 * 4, 16#08000#, 16#08003#, 100);
        run(3, "overlapping VRAM copy");

        desc(0, 1, 0 * 4, 0, 16#FFF0#, 40, fill => 16#C3#);
        run(0, "fill C64 RAM, wrapping at 64 KB", c64 => true);

        desc(0, 0, 2 + 2 * 4, 16#1FFFF0#, 16#000100#, 40);
        desc(1, 0, 1 + 2 * 4, 16#00200#, 16#1FFFFA#, 20);
        desc(0, 0, 2 + 2 * 4, 16#1FFFF0#, 16#000100#, 40, nxt => 1);
        run(0, "XRAM wrap, chained");

        -- C64 RAM into the palette: entries 0-15 and above
        desc(0, 0, 0 + 1 * 4, 16#2000#, 16#20000#, 200);
        run(0, "copy C64 RAM to the palette", c64 => true, check_regs => true);

        -- and back out, from the register space
        desc(1, 0, 1 + 0 * 4, 16#20010#, 16#3000#, 100);
        run(1, "copy palette to C64 RAM", c64 => true);

        -- a chain 0 -> 1 -> 2 -> 0 (ends: 0 already ran), IRQ on 1, reserved op on 2
        desc(0, 1, 2 * 4, 0, 16#040000#, 64, fill => 16#11#, nxt => 1);
        desc(1, 1, 2 * 4 + 32, 0, 16#040040#, 64, fill => 16#22#, nxt => 2);
        desc(2, 7, 2 * 4, 0, 16#040080#, 64, fill => 16#33#, nxt => 0);
        run(0, "chain with IRQ and a reserved operation");

        -- expand and masked expand
        rd(16#D05B#, v);
        if v /= x"1F" then
            fail("CAP_BLIT $" & hex(v) & ", want $1F");
        end if;
        desc(0, 3, 2 + 1 * 4, 16#012345#, 16#06003#, 1003, fill => 16#A1#, tr => 16#B2#);
        run(0, "expand XRAM to VRAM, 1003 pixels");
        desc(1, 4, 1 + 1 * 4 + 16, 16#00F00#, 16#06805#, 37, 9, 5, 320, fill => 16#C4#);
        run(1, "2D masked expand VRAM to VRAM");
        desc(2, 3, 0 + 2 * 4 + 16, 16#C123#, 16#060007#, 21, 6, 3, 64, fill => 16#5D#, tr => 16#00#);
        run(2, "2D expand C64 RAM to XRAM", c64 => true);
        desc(3, 4, 1 + 1 * 4, 16#20013#, 16#07001#, 40, fill => 16#E7#);
        run(3, "masked expand from the palette");
        -- remap: tables in VRAM (unaligned, and wrapping at the top)
        desc(0, 5, 2 + 1 * 4, 16#020000#, 16#06200#, 700, tr => 16#00#, tbl => 16#01F03#);
        run(0, "remap XRAM to VRAM, transparent 0");
        desc(1, 5, 0 + 2 * 4 + 16, 16#C200#, 16#061000#, 19, 7, 40, 64, tr => 16#FF#, tbl => 16#1FF85#);
        run(1, "2D remap C64 RAM to XRAM, table wrapping", c64 => true);
        desc(2, 5, 1 + 1 * 4, 16#20020#, 16#06600#, 64, tr => 16#100# - 1, tbl => 16#00807#);
        run(2, "remap from the register space");
        desc(3, 5, 1 + 1 * 4, 16#06700#, 16#01F03#, 200, tr => 16#13#, tbl => 16#01F03#);
        run(3, "remap into its own table");

        -- mirror (+64) and backwards (+128), signed strides
        desc(0, 0, 2 + 1 * 4 + 64, 16#012345#, 16#07100#, 50);
        run(0, "mirrored copy XRAM to VRAM");
        desc(1, 0, 1 + 1 * 4 + 128, 16#07100#, 16#07103#, 40);
        run(1, "backwards copy over itself, 3 bytes right");
        desc(2, 0, 1 + 1 * 4, 16#07100#, 16#070FE#, 40);
        run(2, "forwards copy over itself, 2 bytes left");
        desc(3, 0, 1 + 1 * 4 + 16 + 128, 16#07000#, 16#07040#, 29, 11, 64, 64);
        run(3, "2D backwards copy, rows overlapping");
        desc(0, 0, 2 + 1 * 4 + 16, 16#030000#, 16#07FC0#, 37, 9, 16#FEC0#, 16#FFC0#);
        run(0, "2D copy, both strides negative");
        desc(1, 3, 0 + 1 * 4 + 16 + 64, 16#C300#, 16#07400#, 21, 5, 3, 16#FFE0#, fill => 16#6B#, tr => 16#7C#);
        run(1, "2D mirrored expand, negative destination stride", c64 => true);
        desc(2, 4, 1 + 2 * 4 + 16 + 64 + 128, 16#00F00#, 16#062000#, 37, 6, 5, 40, fill => 16#91#);
        run(2, "2D masked expand, mirrored and backwards, to XRAM");
        desc(3, 5, 2 + 1 * 4 + 16 + 128, 16#020100#, 16#07600#, 33, 4, 16#FF00#, 64, tr => 16#00#, tbl => 16#01F03#);
        run(3, "2D remap backwards, negative source stride");
        desc(0, 1, 2 * 4 + 16 + 64 + 128, 0, 16#063000#, 9, 5, 0, 16#FFF0#, fill => 16#E1#);
        run(0, "2D fill, mirrored, backwards, negative stride");
        -- scaled copy: zoom in, zoom out, fractions, with mirror and backwards
        desc(0, 6, 2 + 1 * 4 + 16, 16#030200#, 16#07800#, 70, 30, 40, 80, tr => 16#00#, xs => 16#0080#, ys => 16#0080#);
        run(0, "2D scaled copy XRAM to VRAM, twice the size");
        desc(1, 6, 1 + 2 * 4 + 16, 16#06000#, 16#064000#, 33, 13, 256, 40, tr => 16#13#, xs => 16#0233#, ys => 16#01C7#);
        run(1, "2D scaled copy VRAM to XRAM, smaller by odd steps");
        desc(2, 6, 0 + 1 * 4 + 16 + 64, 16#C400#, 16#07A00#, 50, 7, 16#FFD8#, 64, tr => 16#FF#, xs => 16#00C0#, ys => 16#0155#);
        run(2, "2D scaled copy, mirrored, negative source stride", c64 => true);
        desc(3, 6, 1 + 1 * 4 + 16 + 128, 16#07800#, 16#07810#, 40, 12, 80, 80, tr => 16#00#, xs => 16#00F0#, ys => 16#0100#);
        run(3, "2D scaled copy backwards over itself");
        desc(0, 6, 2 + 1 * 4, 16#030000#, 16#07C00#, 200, tr => 16#00#, xs => 16#0001#);
        run(0, "scaled copy, step 1/256: one source byte");

        -- lists in VRAM: entries written through port 1 (and to the
        -- reference), the list address at $2085C-$2085E
        lst(16#09000#, 0, 1, 1 * 4, 0, 16#09400#, 40, fill => 16#21#);
        lst(16#09000#, 1, 0, 1 + 1 * 4, 16#09400#, 16#09500#, 40);
        lst(16#09000#, 2, 1, 1 * 4 + 32, 0, 16#09600#, 9, fill => 16#5C#);
        lst(16#09000#, 3, 6, 2 + 1 * 4 + 16, 16#030200#, 16#09700#, 17, 5, 40, 64, tr => 16#00#, xs => 16#00A0#, ys => 16#0180#);
        lst_end(16#09000#, 4);
        list_at(16#09000#);
        run(0, "list: fill, copy of it, IRQ, scaled copy", list => true);
        -- an entry that changes the next one's fill value; a reserved one
        lst(16#09800#, 0, 1, 1 * 4, 0, 16#09800# + 32 + 18, 1, fill => 16#99#);
        lst(16#09800#, 1, 1, 1 * 4, 0, 16#09900#, 6, fill => 16#11#);
        lst(16#09800#, 2, 7, 1 * 4, 0, 16#09A00#, 6, fill => 16#22#);
        lst(16#09800#, 3, 1, 1 * 4, 0, 16#09B00#, 6, fill => 16#33#);
        lst_end(16#09800#, 4);
        list_at(16#09800#);
        run(3, "list: an entry changes the next; a reserved one is skipped", list => true);
        -- a list wrapping at the top of VRAM
        lst(16#1FFF0#, 0, 1, 1 * 4, 0, 16#09C00#, 5, fill => 16#44#);
        lst(16#1FFF0#, 1, 0, 0 + 1 * 4, 16#C000#, 16#09C10#, 30);
        lst_end(16#1FFF0#, 2);
        list_at(16#1FFF0#);
        run(1, "list wrapping at the top of VRAM", c64 => true, list => true);

        -- a DMA write reaches a port's copy of its block
        port_set(0, 16#05000#);
        rd(16#D04F#, v);                    -- port 0 now holds $05001's block
        idle(200);
        desc(0, 1, 1 * 4, 0, 16#05001#, 2, fill => 16#9E#);
        run(0, "fill under a port's copy");
        rd(16#D04F#, v);
        if v /= x"9E" then
            fail("port 0 read $" & hex(v) & " after the DMA, want $9E");
        end if;

        -- a start while busy is ignored
        desc(0, 1, 1 * 4, 0, 16#10000#, 20000, fill => 16#44#);
        desc(1, 1, 1 * 4, 0, 16#18000#, 100, fill => 16#55#);
        wr(16#D05A#, 0);
        wr(16#D05A#, 1);                    -- ignored
        idle(4000);
        rd(16#D05A#, v);
        if v(7) = '0' then
            fail("a 20,000-byte fill finished within 4,000 clocks");
        end if;
        loop
            rd(16#D05A#, v, 64);
            exit when v(7) = '0';
        end loop;
        for a in 16#10000# to 16#10000# + 19999 loop
            ref.put(1, a, 16#44#);
        end loop;
        desc(0, 1, 1 * 4, 0, 0, 0);         -- width 0: nothing
        run(0, "start while busy, then width 0");

        -- a big background copy while layer 0 (an 8-bit bitmap) fetches
        -- every line, as the gallery demo does
        port_set(1, 16#20800#);
        for k in 0 to 14 loop
            if k = 0 then wr(16#D053#, 3); elsif k = 12 then wr(16#D053#, 64);
            elsif k = 13 then wr(16#D053#, 1); else wr(16#D053#, 0); end if;
            ref.put(3, 16#800# + k, 0);
        end loop;
        ref.put(3, 16#800#, 3); ref.put(3, 16#80C#, 64); ref.put(3, 16#80D#, 1);
        wr(16#D048#, 16#11#);
        desc(0, 0, 2 + 1 * 4, 16#040000#, 16#10000#, 64000);
        run(0, "64,000-byte copy XRAM to VRAM with the layer on");
        desc(0, 0, 2 + 1 * 4, 16#050000#, 16#20040#, 960);
        run(0, "palette fade copy with the layer on", check_regs => true);
        wr(16#D048#, 0);

        -- XRAM windows: W0 page $123 at $A000, W1 page $7FF at $2000, then
        -- W1 also at $A000 (W0 wins), then W0 off
        wr(16#D054#, 16#23#); wr(16#D055#, 16#01#); wr(16#D056#, 16#84#);
        wr(16#D057#, 16#FF#); wr(16#D058#, 16#07#); wr(16#D059#, 16#80#);
        win_check : for k in 0 to 5 loop
            case k is
                when 0 => bus_addr <= x"A123";
                when 1 => bus_addr <= x"2FFF";
                when 2 => bus_addr <= x"C000";
                when 3 => wr(16#D059#, 16#84#); bus_addr <= x"BFFF";
                when 4 => wr(16#D056#, 16#04#); bus_addr <= x"B000";
                when others => bus_addr <= x"E000";
            end case;
            wait for 1 ns;
            -- 2 MB of XRAM: addresses wrap at $200000
            if (k = 0 and (win_hit /= '1' or unsigned(win_addr) /= 16#1000000# + (16#123# * 8192 + 16#0123#) mod 16#200000#)) or
               (k = 1 and (win_hit /= '1' or unsigned(win_addr) /= 16#1000000# + (16#7FF# * 8192 + 16#0FFF#) mod 16#200000#)) or
               (k = 2 and win_hit /= '0') or
               (k = 3 and (win_hit /= '1' or unsigned(win_addr) /= 16#1000000# + (16#123# * 8192 + 16#1FFF#) mod 16#200000#)) or
               (k = 4 and (win_hit /= '1' or unsigned(win_addr) /= 16#1000000# + (16#7FF# * 8192 + 16#1000#) mod 16#200000#)) or
               (k = 5 and win_hit /= '0') then
                fail("XRAM window case " & integer'image(k) & ": hit " & std_logic'image(win_hit) &
                     " at $" & hex(win_addr(23 downto 0)));
            end if;
        end loop;

        if bad_addr > 0 then
            fail(integer'image(bad_addr) & " accesses outside the three spaces");
        end if;
        if errors = 0 then
            report "PASS: VIC-X DMA";
        else
            report "FAILED: VIC-X DMA, " & integer'image(errors) & " failures" severity error;
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
