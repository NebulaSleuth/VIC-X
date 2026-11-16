-- Testbench for VIC-X step 1: unlock, ID and capability registers, ports,
-- register space, palette, colour remapping, frame counter and IRQ.
-- Expected values follow the VICE fork and conformance tests t01-t08.
-- Run with hdl/run_sim.sh; prints PASS or the first failures and exits 1.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.env.all;
use work.vicx_pkg.all;

entity tb_vicx_step1 is
    generic (
        EXT    : boolean := false;  -- VRAM through the vx_* port, with a memory model
        GAP    : natural := 8;      -- clocks per CPU access (128 = four C64 cycles)
        MAXLAT : natural := 16;     -- the model's longest wait for a slot, in clocks
        SEED   : positive := 1
    );
end entity;

architecture sim of tb_vicx_step1 is

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
    signal xram_mb   : std_logic_vector(7 downto 0) := x"02";
    signal stock     : rgb_array;
    signal frame_st  : std_logic := '0';
    signal line_st   : std_logic := '0';
    signal vic_idx   : std_logic_vector(3 downto 0) := (others => '0');
    signal vic_rgb   : std_logic_vector(23 downto 0) := (others => '0');
    signal rgb_out   : std_logic_vector(23 downto 0);

    signal done      : boolean := false;

    -- external VRAM port and its model
    signal vx_req, vx_we, vx_ack, vx_rvalid, vx_miss : std_logic := '0';
    signal vx_addr   : std_logic_vector(16 downto 0);
    signal vx_din    : std_logic_vector(15 downto 0);
    signal vx_be     : std_logic_vector(1 downto 0);
    signal vx_rdata  : std_logic_vector(63 downto 0) := (others => '0');
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

    -- a stock palette that is easy to recognise: entry i = $i0, $i1, $i2
    stock_init : for i in 0 to 15 generate
        stock(i) <= std_logic_vector(to_unsigned(i * 16, 8)) &
                    std_logic_vector(to_unsigned(i * 16 + 1, 8)) &
                    std_logic_vector(to_unsigned(i * 16 + 2, 8));
    end generate;

    dut : entity work.vicx
        generic map (VRAM_BITS => 17, CAP_SPR => 0, CAP_SPRLINE => 0, CAP_FEAT => x"00",
                     EXT_VRAM => EXT)
        port map (
            clk => clk, reset => reset,
            vic_cs => vic_cs, cpu_addr => cpu_addr, cpu_din => cpu_din,
            cpu_wr => cpu_wr, cpu_rd => cpu_rd, claim => claim,
            cpu_dout => cpu_dout, irq => irq,
            xram_mb => xram_mb, stock_rgb => stock,
            frame_start => frame_st, line_start => line_st,
            vic_idx => vic_idx, vic_rgb => vic_rgb, rgb_out => rgb_out,
            vx_req => vx_req, vx_we => vx_we, vx_addr => vx_addr, vx_din => vx_din,
            vx_be => vx_be, vx_ack => vx_ack, vx_rdata => vx_rdata,
            vx_rvalid => vx_rvalid, vx_miss => vx_miss);

    -- external memory: answers like the SDRAM controller's VIC-X port, after
    -- a random wait for a free slot; a read's data come 4 clocks after ack
    mem_model : process
        type mem_t is array (0 to 131071) of std_logic_vector(7 downto 0);
        variable mem : mem_t := (others => x"00");
        variable s1, s2 : positive := SEED;
        variable r : real;
        variable a : natural;
        variable blk : std_logic_vector(63 downto 0);
    begin
        wait until rising_edge(clk) and vx_req = '1';
        uniform(s1, s2, r);
        for i in 1 to 1 + integer(trunc(r * real(MAXLAT))) loop
            wait until rising_edge(clk);
        end loop;
        a := to_integer(unsigned(vx_addr));
        if vx_we = '1' then
            if vx_be(0) = '1' then mem((a / 2) * 2) := vx_din(7 downto 0); end if;
            if vx_be(1) = '1' then mem((a / 2) * 2 + 1) := vx_din(15 downto 8); end if;
        else
            for n in 0 to 7 loop
                blk(8 * n + 7 downto 8 * n) := mem((a / 8) * 8 + n);
            end loop;
        end if;
        requests <= requests + 1;
        vx_ack <= '1';
        wait until rising_edge(clk);
        vx_ack <= '0';
        if vx_we = '0' then
            for i in 1 to 3 loop
                wait until rising_edge(clk);
            end loop;
            vx_rdata <= blk;
            vx_rvalid <= '1';
            wait until rising_edge(clk);
            vx_rvalid <= '0';
        end if;
    end process;

    count_miss : process (clk)
    begin
        if rising_edge(clk) and vx_miss = '1' then
            misses <= misses + 1;
        end if;
    end process;

    stim : process

        variable errors : natural := 0;

        procedure idle(n : natural) is
        begin
            for i in 1 to n loop
                wait until rising_edge(clk);
            end loop;
        end procedure;

        -- one CPU write; addr is the full C64 address, cs says whether it
        -- falls in $D000-$D3FF with I/O mapped in
        -- g: clocks this access takes (0 = GAP)
        procedure wr(addr : natural; val : natural; cs : std_logic := '1'; g : natural := 0) is
        begin
            cpu_addr <= std_logic_vector(to_unsigned(addr mod 1024, 10));
            cpu_din  <= std_logic_vector(to_unsigned(val, 8));
            vic_cs   <= cs;
            cpu_wr   <= '1';
            wait until rising_edge(clk);
            cpu_wr   <= '0';
            vic_cs   <= '0';
            if g = 0 then idle(GAP - 1); else idle(g - 1); end if;
        end procedure;

        procedure rd(addr : natural; val : out std_logic_vector(7 downto 0);
                     owned : out std_logic; g : natural := 0) is
        begin
            cpu_addr <= std_logic_vector(to_unsigned(addr mod 1024, 10));
            vic_cs   <= '1';
            cpu_rd   <= '1';
            wait for 1 ns;
            owned    := claim;
            wait until rising_edge(clk);
            cpu_rd   <= '0';
            vic_cs   <= '0';
            idle(3);
            val      := cpu_dout;
            if g = 0 then idle(GAP - 4); else idle(g - 4); end if;
        end procedure;

        procedure fail(msg : string) is
        begin
            report "FAIL: " & msg severity error;
            errors := errors + 1;
        end procedure;

        procedure expect(addr : natural; want : natural; what : string) is
            variable v : std_logic_vector(7 downto 0);
            variable o : std_logic;
        begin
            rd(addr, v, o);
            if o /= '1' then
                fail(what & ": $" & hex(std_logic_vector(to_unsigned(addr, 16))) & " not claimed");
            elsif to_integer(unsigned(v)) /= want then
                fail(what & ": read $" & hex(v) & ", want $" &
                     hex(std_logic_vector(to_unsigned(want, 8))));
            end if;
        end procedure;

        procedure expect_locked(addr : natural; what : string) is
            variable v : std_logic_vector(7 downto 0);
            variable o : std_logic;
        begin
            rd(addr, v, o);
            if o /= '0' then
                fail(what & ": $" & hex(std_logic_vector(to_unsigned(addr, 16))) & " claimed while locked");
            end if;
        end procedure;

        procedure unlock is
        begin
            wr(16#D06F#, 16#56#);
            wr(16#D06F#, 16#58#);
            wr(16#D06F#, 16#21#);
        end procedure;

        procedure port0(addr : natural; step : natural) is
        begin
            wr(16#D04C#, addr mod 256);
            wr(16#D04D#, (addr / 256) mod 256);
            wr(16#D04E#, (addr / 65536) mod 4 + step);
        end procedure;

        procedure port1(addr : natural; step : natural) is
        begin
            wr(16#D050#, addr mod 256);
            wr(16#D051#, (addr / 256) mod 256);
            wr(16#D052#, (addr / 65536) mod 4 + step);
        end procedure;

        procedure pulse(signal s : out std_logic) is
        begin
            s <= '1';
            wait until rising_edge(clk);
            s <= '0';
            idle(2);
        end procedure;

        procedure expect_rgb(idx : natural; core : natural; want : natural; what : string) is
        begin
            vic_idx <= std_logic_vector(to_unsigned(idx, 4));
            vic_rgb <= std_logic_vector(to_unsigned(core, 24));
            idle(3);
            if to_integer(unsigned(rgb_out)) /= want then
                fail(what & ": rgb $" & hex(rgb_out) & ", want $" &
                     hex(std_logic_vector(to_unsigned(want, 24))));
            end if;
        end procedure;

        constant STEP1  : natural := 1 * 8;     -- step code 1 = +1
        constant STEP40 : natural := 7 * 8;     -- step code 7 = +40
        constant BACK   : natural := 16#80#;
        variable v : std_logic_vector(7 downto 0);
        variable o : std_logic;

        -- stress test state
        type ref_t is array (16#0E00# to 16#1200#) of integer;
        type int2 is array (0 to 1) of integer;
        type steps_t is array (0 to 4) of natural;
        constant STEPS : steps_t := (0, 1, 2, 4, 8);
        variable ref : ref_t := (others => -1);
        variable ra, rs : int2 := (others => 0);
        variable s1, s2 : positive := SEED + 11;
        variable r : real;
        variable p, sc, d : natural;

    begin
        reset <= '1';
        idle(4);
        reset <= '0';
        idle(2700);                             -- let the register-space sweep finish

        -- t01: locked, nothing claimed
        expect_locked(16#D040#, "t01 locked");
        expect_locked(16#D06F#, "t01 locked");

        -- t03: unlock, and what cancels it
        unlock;
        expect(16#D040#, 16#56#, "t03 ID");
        wr(16#D06F#, 0);
        expect_locked(16#D040#, "t03 relock");

        wr(16#D06F#, 16#56#); wr(16#D020#, 0); wr(16#D06F#, 16#58#); wr(16#D06F#, 16#21#);
        expect_locked(16#D040#, "t03 VIC-II write cancels");

        wr(16#D06F#, 16#56#); wr(16#D120#, 0); wr(16#D06F#, 16#58#); wr(16#D06F#, 16#21#);
        expect_locked(16#D040#, "t03 mirror write cancels");

        wr(16#D06F#, 16#56#); wr(16#0400#, 1, '0'); wr(16#D06F#, 16#58#); wr(16#D06F#, 16#21#);
        expect(16#D040#, 16#56#, "t03 RAM write does not cancel");
        wr(16#D06F#, 0);

        wr(16#D06F#, 16#56#); wr(16#D06F#, 16#56#); wr(16#D06F#, 16#58#); wr(16#D06F#, 16#21#);
        expect(16#D040#, 16#56#, "t03 repeated $56 restarts");
        wr(16#D06F#, 0);

        wr(16#D06F#, 16#56#); wr(16#D06F#, 16#58#); wr(16#D06F#, 16#22#); wr(16#D06F#, 16#21#);
        expect_locked(16#D040#, "t03 wrong byte cancels");

        -- t04: ID and capabilities
        unlock;
        expect(16#D040#, 16#56#, "t04 ID");
        expect(16#D041#, 16#58#, "t04 ID");
        expect(16#D042#, 16#01#, "t04 VERSION");
        expect(16#D043#, 16#10#, "t04 CAP_VRAM");
        expect(16#D044#, 16#02#, "t04 CAP_XRAM");
        expect(16#D045#, 0, "t04 CAP_SPR");
        expect(16#D046#, 0, "t04 CAP_SPRLINE");
        expect(16#D047#, 0, "t04 CAP_FEAT");
        for a in 16#D05B# to 16#D06F# loop
            expect(a, 16#FF#, "t04 reserved");
        end loop;
        rd(16#D140#, v, o);
        if o = '1' then fail("t04 mirror $D140 claimed"); end if;
        rd(16#D070#, v, o);
        if o = '1' then fail("t04 $D070 claimed"); end if;

        -- CTRL, IRQ_EN masks; relock keeps values
        wr(16#D048#, 16#FF#);
        expect(16#D048#, 16#1F#, "CTRL mask");
        wr(16#D049#, 16#FF#);
        expect(16#D049#, 16#07#, "IRQ_EN mask");
        wr(16#D06F#, 0);
        unlock;
        expect(16#D048#, 16#1F#, "CTRL kept over relock");
        wr(16#D048#, 0);
        wr(16#D049#, 0);

        -- window registers: masks
        wr(16#D054#, 16#AB#); wr(16#D055#, 16#FF#); wr(16#D056#, 16#FF#);
        wr(16#D057#, 16#12#); wr(16#D058#, 16#0D#); wr(16#D059#, 16#03#);
        expect(16#D054#, 16#AB#, "W0_PAGE lo");
        expect(16#D055#, 16#07#, "W0_PAGE hi mask");
        expect(16#D056#, 16#87#, "W0_SLOT mask");
        expect(16#D058#, 16#05#, "W1_PAGE hi mask");
        expect(16#D059#, 16#03#, "W1_SLOT");
        expect(16#D05A#, 0, "DMA_CMD idle");

        -- t05: ports, steps, address readback
        port0(16#00010#, STEP1);
        expect(16#D04C#, 16#10#, "t05 P0 lo");
        expect(16#D04E#, STEP1, "t05 P0 hi + step");
        for i in 0 to 7 loop
            wr(16#D04F#, 16#A0# + i);
        end loop;
        expect(16#D04C#, 16#18#, "t05 P0 stepped");
        port1(16#00010#, STEP1);
        for i in 0 to 7 loop
            expect(16#D053#, 16#A0# + i, "t05 P1 reads VRAM");
        end loop;
        port1(16#00017#, STEP1 + BACK);
        expect(16#D053#, 16#A7#, "t05 backwards");
        expect(16#D053#, 16#A6#, "t05 backwards");
        expect(16#D050#, 16#15#, "t05 backwards address");
        expect(16#D052#, STEP1 + BACK, "t05 backwards code");
        port0(16#00100#, STEP40);
        wr(16#D04F#, 1); wr(16#D04F#, 2);
        port1(16#00128#, 0);
        expect(16#D053#, 2, "t05 step 40");
        expect(16#D053#, 2, "t05 step 0 stays");
        port0(16#3FFFF#, STEP1);
        wr(16#D04F#, 0);
        expect(16#D04C#, 0, "t05 18-bit wrap");
        expect(16#D04E#, STEP1, "t05 18-bit wrap");
        wr(16#D04E#, 16#FF#);
        expect(16#D04E#, 16#FB#, "t05 bit 2 reserved");

        -- register space: unmapped, regs, palette
        port1(16#20A00#, STEP1);
        expect(16#D053#, 16#FF#, "unmapped $20A00");
        port0(16#20800#, STEP1);
        wr(16#D04F#, 16#5A#);
        port1(16#20800#, 0);
        expect(16#D053#, 16#5A#, "register space write");

        -- t07: palette, stock entries until first access
        port1(16#20004#, STEP1);
        expect(16#D053#, 16#10#, "t07 stock entry 1 R");
        expect(16#D053#, 16#11#, "t07 stock entry 1 G");
        expect(16#D053#, 16#12#, "t07 stock entry 1 B");
        expect(16#D053#, 16#00#, "t07 stock entry 1 spare");
        port0(16#20014#, STEP1);                -- entry 5
        wr(16#D04F#, 16#11#); wr(16#D04F#, 16#22#); wr(16#D04F#, 16#33#); wr(16#D04F#, 16#44#);
        port1(16#20014#, STEP1);
        expect(16#D053#, 16#11#, "t07 entry 5 R");
        expect(16#D053#, 16#22#, "t07 entry 5 G");
        expect(16#D053#, 16#33#, "t07 entry 5 B");
        expect(16#D053#, 16#44#, "t07 entry 5 spare");
        port0(16#200FC#, STEP1);                -- entry 63
        wr(16#D04F#, 16#77#);
        port1(16#200FC#, 0);
        expect(16#D053#, 16#77#, "t07 entry 63");

        -- t08: remap, latched per line, palette writes immediate
        pulse(line_st);
        expect_rgb(5, 16#ABCDEF#, 16#ABCDEF#, "t08 remap off");
        wr(16#D048#, 16#08#);
        expect_rgb(5, 16#ABCDEF#, 16#ABCDEF#, "t08 remap waits for the next line");
        pulse(line_st);
        expect_rgb(5, 16#ABCDEF#, 16#112233#, "t08 remap on");
        expect_rgb(1, 16#ABCDEF#, 16#101112#, "t08 stock entry through remap");
        port0(16#20014#, STEP1);
        wr(16#D04F#, 16#99#);
        expect_rgb(5, 16#ABCDEF#, 16#992233#, "t08 palette write immediate");
        wr(16#D048#, 0);
        pulse(line_st);
        expect_rgb(5, 16#ABCDEF#, 16#ABCDEF#, "t08 remap off again");

        -- IRQ and frame counter
        wr(16#D04A#, 16#07#);
        expect(16#D04B#, 0, "FRAME at 0");
        pulse(frame_st);
        expect(16#D04B#, 1, "FRAME counts");
        expect(16#D04A#, 16#04#, "IRQ_STAT frame bit without IRQ_EN");
        if irq /= '0' then fail("IRQ while disabled"); end if;
        wr(16#D049#, 16#04#);
        idle(1);
        if irq /= '1' then fail("IRQ not raised"); end if;
        wr(16#D04A#, 16#04#);
        idle(1);
        if irq /= '0' then fail("IRQ not cleared by write-1"); end if;
        expect(16#D04A#, 0, "IRQ_STAT cleared");

        -- t06: reset locks, clears, restores the palette, keeps VRAM
        wr(16#D048#, 16#08#);
        wr(16#D049#, 16#04#);
        pulse(frame_st);
        reset <= '1';
        idle(2);
        reset <= '0';
        idle(1);
        if irq /= '0' then fail("t06 IRQ after reset"); end if;
        expect_locked(16#D040#, "t06 reset locks");
        unlock;
        expect(16#D048#, 0, "t06 CTRL cleared");
        expect(16#D04B#, 0, "t06 FRAME cleared");
        expect(16#D04C#, 0, "t06 port cleared");
        port1(16#20014#, STEP1);
        expect(16#D053#, 16#50#, "t06 palette entry 5 back to stock");
        port1(16#20800#, 0);
        expect(16#D053#, 0, "t06 register space reads cleared during the sweep");
        idle(2700);
        expect(16#D053#, 0, "t06 register space cleared");
        port1(16#200FC#, 0);
        expect(16#D053#, 0, "t06 entry 63 cleared");
        port1(16#00010#, STEP1);
        expect(16#D053#, 16#A0#, "t06 VRAM kept");

        -- both ports at random over a small area, so they keep landing in
        -- each other's 8-byte blocks: every read must see every earlier write
        for i in 1 to 2500 loop
            uniform(s1, s2, r);
            p := integer(trunc(r * 2.0));
            uniform(s1, s2, r);
            if r < 0.15 or i <= 2 or ra(p) < 16#0E10# or ra(p) > 16#11F0# then
                -- new address (and step) for one port
                uniform(s1, s2, r);
                ra(p) := 16#1000# + integer(trunc(r * 96.0));
                uniform(s1, s2, r);
                sc := integer(trunc(r * 5.0));      -- step codes 0-4: 0, 1, 2, 4, 8
                rs(p) := STEPS(sc);
                uniform(s1, s2, r);
                if r < 0.3 then
                    sc := sc + 16;                  -- backwards
                    rs(p) := -rs(p);
                end if;
                if p = 0 then port0(ra(p), sc * 8); else port1(ra(p), sc * 8); end if;
            elsif r < 0.25 then
                -- INC on the data port: read, then two writes on the next two
                -- bus cycles (the 6510 writes the old value back first)
                rd(16#D04F# + 4 * p, v, o, 32);
                if ref(ra(p)) >= 0 and to_integer(unsigned(v)) /= ref(ra(p)) then
                    fail("stress: INC port " & integer'image(p) & " read $" & hex(v)
                         & " at " & integer'image(ra(p)) & ", want "
                         & integer'image(ref(ra(p))));
                end if;
                d := to_integer(unsigned(v));
                ra(p) := ra(p) + rs(p);
                wr(16#D04F# + 4 * p, d, '1', 32);
                ref(ra(p)) := d;
                ra(p) := ra(p) + rs(p);
                wr(16#D04F# + 4 * p, (d + 1) mod 256);
                ref(ra(p)) := (d + 1) mod 256;
                ra(p) := ra(p) + rs(p);
            elsif r < 0.6 then
                uniform(s1, s2, r);
                d := integer(trunc(r * 256.0));
                wr(16#D04F# + 4 * p, d);
                ref(ra(p)) := d;
                ra(p) := ra(p) + rs(p);
            else
                rd(16#D04F# + 4 * p, v, o);
                if ref(ra(p)) >= 0 and to_integer(unsigned(v)) /= ref(ra(p)) then
                    fail("stress: port " & integer'image(p) & " read $" & hex(v)
                         & " at " & integer'image(ra(p)) & ", want "
                         & integer'image(ref(ra(p))));
                end if;
                ra(p) := ra(p) + rs(p);
            end if;
        end loop;

        if misses /= 0 then
            fail(integer'image(misses) & " port reads found no data ready");
        end if;
        if EXT then
            report "external VRAM: " & integer'image(requests) & " requests, GAP "
                   & integer'image(GAP) & ", MAXLAT " & integer'image(MAXLAT);
        end if;

        if errors = 0 then
            report "PASS: VIC-X step 1" severity note;
        else
            report integer'image(errors) & " failure(s)" severity note;
        end if;
        done <= true;
        if errors = 0 then
            finish;
        else
            stop(1);
        end if;
        wait;
    end process;

end architecture;
