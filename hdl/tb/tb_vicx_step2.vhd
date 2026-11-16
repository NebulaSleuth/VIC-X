-- Testbench for VIC-X step 2: layer 0 as a 4- or 8-bit bitmap behind the
-- VIC-II.  A video generator makes PAL lines (63 cycles of 32 clocks, a
-- pixel every 4 clocks, the 320x200 window from 15 cycles after the line
-- starts) with random VIC-II colours and background flags, and every
-- pixel the block puts out is compared with what the spec says it should
-- be.  Expected values follow the VICE fork (layer_line and mix_line in
-- src/vicx/vicx.c) and conformance tests t10-t14.
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

entity tb_vicx_step2 is
    generic (
        EXT  : boolean := false;    -- VRAM through the vx_* port
        REU  : boolean := false;    -- REU DMA holds the DMA0 slot (EXT only)
        WX   : natural := 120       -- first window pixel in the line
    );
end entity;

architecture sim of tb_vicx_step2 is

    constant LINE_CLK  : natural := 63 * 32;
    constant LINE_PIX  : natural := LINE_CLK / 4;
    constant LINES     : natural := 312;

    type vram_t is array (0 to 131071) of std_logic_vector(7 downto 0);
    type pal_t  is array (0 to 255) of std_logic_vector(23 downto 0);
    type set_t  is array (0 to 31) of std_logic_vector(7 downto 0);

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
    signal ref_set   : set_t := (others => (others => '0'));
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
        generic map (VRAM_BITS => 17, CAP_SPR => 0, CAP_SPRLINE => 0, CAP_FEAT => x"02",
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
        variable t     : integer := -1;
        variable a     : natural;
        variable slot  : natural;
        variable blk   : std_logic_vector(63 downto 0);
    begin
        if rising_edge(clk) then
            vx_ack    <= '0';
            vx_rvalid <= '0';
            if t >= 0 then
                t := t + 1;
                if t = 4 then
                    vx_rdata  <= blk;
                    vx_rvalid <= '1';
                    t := -1;
                end if;
            end if;
            slot := (cnt / 4) mod 8;
            if EXT and t < 0 and cnt mod 4 = 0 and vx_req = '1' and
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
                    t := 0;
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
        variable st         : set_t := (others => (others => '0'));
        variable exp        : std_logic_vector(23 downto 0);
        variable exp_ok     : boolean := false;
        variable exp_lay    : boolean := false;
        variable exp_x      : integer;
        variable exp_ln     : natural;
        variable idx        : natural;
        variable li         : natural;
        variable lx, y      : natural;
        variable row, base, stride : natural;
        variable b          : std_logic_vector(7 downto 0);
        variable n          : natural;
        variable in_win     : boolean;
        variable bg         : std_logic;
        variable err_n, cmp_n, shown_n, late_n : natural := 0;

        impure function rnd(m : natural) return natural is
        begin
            s1 := (s1 * 1103 + 12347) mod 65536;
            return (s1 / 16) mod m;
        end function;
    begin
        wait until rising_edge(clk);

        -- the pixel the block took at this edge: work out what it should show
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
            ctl := ref_ctrl;        -- latched with the block
            st  := ref_set;
        end if;

        if pix_ce = '1' then
            idx := to_integer(unsigned(vic_idx));
            if ctl(3) = '1' then
                exp := ref_pal(idx);
            else
                exp := stock_of(idx);
            end if;
            exp_lay := false;
            if vic_win = '1' and ctl(0) = '1' and st(0)(1) = '1' then
                y      := to_integer(unsigned(raster_y)) - 51;
                lx     := px - WX;
                if st(0)(3) = '1' then lx := lx / 2; end if;
                base   := to_integer(unsigned(st(4)(0 downto 0)) & unsigned(st(3)) & unsigned(st(2)));
                stride := to_integer(unsigned(st(13)(2 downto 0)) & unsigned(st(12)));
                row    := base + y * stride;
                if st(0)(0) = '1' then
                    li := to_integer(unsigned(ref_vram((row + lx) mod 131072)));
                else
                    b := ref_vram((row + lx / 2) mod 131072);
                    if lx mod 2 = 0 then
                        n := to_integer(unsigned(b(7 downto 4)));
                    else
                        n := to_integer(unsigned(b(3 downto 0)));
                    end if;
                    if n = 0 then
                        li := 0;
                    else
                        li := to_integer(unsigned(st(14)(3 downto 0))) * 16 + n;
                    end if;
                end if;
                if li /= 0 and ctl(4) = '1' and vic_bg = '1' then
                    exp := ref_pal(li);
                    exp_lay := true;
                end if;
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
            if in_win then
                vic_win <= '1';
                if rnd(4) /= 0 then bg := '1'; else bg := '0'; end if;
                vic_bg <= bg;
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

        -- one byte of the layer 0 setup through port 1, which must point at it
        procedure set_byte(off : natural; val : natural; g : natural := 8) is
        begin
            cpu_addr <= std_logic_vector(to_unsigned(16#53#, 10));
            cpu_din  <= std_logic_vector(to_unsigned(val, 8));
            vic_cs   <= '1';
            cpu_wr   <= '1';
            wait until rising_edge(clk);
            ref_set(off) <= std_logic_vector(to_unsigned(val, 8));
            cpu_wr   <= '0';
            vic_cs   <= '0';
            idle(g - 1);
        end procedure;

        procedure set_layer(mode, base, stride, bank : natural) is
        begin
            port_set(1, 16#20800#);
            set_byte(0, mode);
            set_byte(1, 0);
            set_byte(2, base mod 256);
            set_byte(3, (base / 256) mod 256);
            set_byte(4, base / 65536);
            for i in 5 to 11 loop
                set_byte(i, 0);
            end loop;
            set_byte(12, stride mod 256);
            set_byte(13, stride / 256);
            set_byte(14, bank);
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
        if v /= x"02" then
            report "FAIL: CAP_FEAT $" & hex(v) & ", want $02" severity error;
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

        -- 8-bit, unaligned base, 320 bytes a line
        set_layer(16#03#, 16#00123#, 320, 0);
        set_ctrl(16#11#);
        frame_check("8-bit, base $00123, stride 320");

        -- double width, wrapping at the top of VRAM
        set_layer(16#0B#, 16#1FF05#, 1000, 0);
        frame_check("8-bit double width, base $1FF05, stride 1000");

        -- 4-bit, bank 5
        set_layer(16#02#, 16#0FFFD#, 160, 5);
        frame_check("4-bit bank 5, base $0FFFD, stride 160");

        -- 4-bit double width; stride bits 0-10 only
        set_layer(16#0A#, 16#1E001#, 16#FFFF#, 16#FA#);
        frame_check("4-bit double width bank 10, stride $7FF");

        -- stride 0 (the same row on every line), colour remapping on
        set_layer(16#03#, 16#04567#, 0, 0);
        set_ctrl(16#19#);
        frame_check("stride 0, CTRL $19");

        -- background not transparent: the VIC-II covers the layer
        set_ctrl(16#01#);
        frame_check("CTRL $01");

        -- layer off
        set_ctrl(16#10#);
        frame_check("CTRL $10");

        -- tile modes draw nothing in this build
        set_layer(16#01#, 0, 320, 0);
        set_ctrl(16#11#);
        frame_check("tile mode");

        -- raster splits: setup and CTRL written in the middle of lines, and
        -- port traffic all frame long
        set_layer(16#03#, 16#00000#, 320, 0);
        wait_frame;
        wait_line(60);
        traffic(20);
        wait_line(100);
        idle(700);
        port_set(1, 16#20802#);
        set_byte(2, 16#40#);
        set_byte(3, 16#9C#);                -- base $09C40
        traffic(40);
        wait_line(150);
        idle(1500);
        port_set(1, 16#20800#);
        set_byte(0, 16#02#);                -- 4-bit
        traffic(30);
        wait_line(180);
        idle(100);
        set_ctrl(16#00#);
        wait_line(190);
        idle(1990);                         -- just before the line starts
        set_ctrl(16#11#);
        port_set(1, 16#2080C#);
        set_byte(12, 16#20#);
        set_byte(13, 16#03#);               -- stride 800
        traffic(60);
        wait_frame;

        -- every byte of a setup rewritten while lines start, and traffic
        set_ctrl(16#11#);
        wait_frame;
        wait_line(120);
        for k in 0 to 9 loop
            set_layer(16#03# + 8 * (k mod 2), 16#00100# * k + k, 320 + k, 0);
        end loop;
        traffic(50);
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
        if shown < 100000 then
            report "FAIL: too few layer pixels shown" severity error;
            errors := errors + 1;
        end if;
        if errors = 0 then
            report "PASS: VIC-X step 2";
        else
            report "FAILED: VIC-X step 2, " & integer'image(errors) & " failures" severity error;
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
