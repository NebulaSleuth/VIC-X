-- VIC-X sprite engine: 128 entries, up to 32 sprites and 640 pixels a line.
--
-- Table: every write to the register space's sprite table ($20400-$207FF)
-- comes in on tw_*, into a live copy; at frame_start the live copy is
-- latched (about 130 clocks) and the frame draws from the latched one.
--
-- Lines: while window line y shows, the engine prepares line y + 1: it
-- picks the entries that cover it (table order; the first that would pass
-- 32 sprites or 640 pixels drops out with every higher entry, and sets the
-- overflow flag), fetches each one's pattern row through f_* (as the
-- layers do; the next row is fetched while one is drawn) and draws it into
-- one of two line buffers: per pixel a front and a behind palette index (a
-- lower entry stays in front) and a mask of the sprites drawn there.  The
-- display reads the other buffer (q_* one clock after x, like the layers)
-- and clears each pixel as it is shown (x_done).
--
-- Collisions: as line y shows, each pixel where two or more sprites were
-- drawn goes into a queue (a pixel with the same sprites as the one before
-- adds nothing new and is left out); pairs whose groups and hit masks meet
-- are added once per frame (lower entry first, in pixel order) to a list of
-- up to 127, one pair a clock.  Only lines shown with the engine on
-- (line_on) count, for collisions and for the overflow flag.  After the
-- window's last line the status byte, the count and the pairs are written
-- out through p_* ($20841, $20900...), and coll_irq pulses if the list is
-- not empty.  Follows sprite_line and sprite_frame_done in the VICE fork
-- (src/vicx/vicx.c).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity vicx_sprites is
    port (
        clk         : in  std_logic;
        reset       : in  std_logic;

        -- writes to the sprite table (offset in it), from the register space
        tw_we       : in  std_logic;
        tw_addr     : in  unsigned(9 downto 0);
        tw_data     : in  std_logic_vector(7 downto 0);

        frame_start : in  std_logic;
        line_start  : in  std_logic;
        raster_y    : in  unsigned(8 downto 0);
        line_on     : in  std_logic;                        -- CTRL bit 2, this line
        win_first   : in  unsigned(8 downto 0);             -- the window's raster lines
        win_last    : in  unsigned(8 downto 0);
        width       : in  unsigned(8 downto 0);             -- window width

        f_req       : out std_logic;
        f_addr      : out unsigned(13 downto 0);
        f_gnt       : in  std_logic;
        f_valid     : in  std_logic;
        f_data      : in  std_logic_vector(63 downto 0);
        f_busy      : out std_logic;                        -- selecting, or rows to fetch

        x           : in  unsigned(8 downto 0);             -- window pixel
        x_done      : in  std_logic;                        -- pixel x is being shown
        q_front     : out std_logic_vector(7 downto 0);
        q_behind    : out std_logic_vector(7 downto 0);

        -- results, written to the register space after the window: hold
        -- p_req with p_addr / p_data until p_ack
        p_req       : out std_logic;
        p_addr      : out unsigned(11 downto 0);
        p_data      : out std_logic_vector(7 downto 0);
        p_ack       : in  std_logic;
        coll_irq    : out std_logic
    );
end entity;

architecture rtl of vicx_sprites is

    signal l_width   : natural range 0 to 511 := 320;  -- the prepared line's width

    type byte_ram is array (0 to 127) of std_logic_vector(7 downto 0);
    type entry_ram is array (0 to 127) of std_logic_vector(63 downto 0);
    type lbuf_t is array (0 to 511) of std_logic_vector(47 downto 0);  -- mask, behind, front
    type sel_t is array (0 to 31) of std_logic_vector(7 downto 0);
    type nib_t is array (0 to 31) of std_logic_vector(3 downto 0);
    type sel2_t is array (0 to 3) of sel_t;      -- four lines' lists
    type nib2_t is array (0 to 3) of nib_t;
    type rowbuf_t is array (0 to 7) of std_logic_vector(63 downto 0);  -- up to 8 blocks
    type rowbuf2_t is array (0 to 1) of rowbuf_t;
    type off2_t is array (0 to 1) of unsigned(2 downto 0);
    type pair_ram is array (0 to 127) of std_logic_vector(15 downto 0);
    type seen_ram is array (0 to 127) of std_logic_vector(127 downto 0);
    type fifo_t is array (0 to 255) of std_logic_vector(33 downto 0);
    type ent_list is array (0 to 31) of std_logic_vector(63 downto 0);
    type row6_t is array (0 to 31) of unsigned(5 downto 0);

    -- the table: live (eight byte lanes) and latched
    signal lat_rd    : std_logic_vector(63 downto 0);
    signal lat_ra    : natural range 0 to 127 := 0;
    signal lat_busy  : std_logic := '0';
    signal lat_v     : std_logic := '0';
    signal lat_k     : natural range 0 to 127 := 0;
    signal latched   : entry_ram := (others => (others => '0'));
    signal ent_q     : std_logic_vector(63 downto 0) := (others => '0');

    -- line buffers: one is drawn (read-modify-write) while the other shows
    -- (read, then cleared)
    signal buf0, buf1 : lbuf_t := (others => (others => '0'));
    signal draw_b    : std_logic := '0';          -- 0: buf0 drawn, buf1 shown
    signal d_ra, d_wa, s_wa : natural range 0 to 511 := 0;
    signal s_ra      : natural range 0 to 511;
    signal d_we, s_we : std_logic := '0';
    signal d_wd      : std_logic_vector(47 downto 0) := (others => '0');
    signal we0, we1  : std_logic;
    signal wa0, wa1, ra0, ra1 : natural range 0 to 511;
    signal wd0, wd1  : std_logic_vector(47 downto 0);
    signal q0, q1    : std_logic_vector(47 downto 0) := (others => '0');
    signal d_q, s_q  : std_logic_vector(47 downto 0);

    -- preparing the next line: select, then fetch rows and draw them
    type st_t is (P_IDLE, P_SEL, P_SEL2, P_RUN);
    signal st        : st_t := P_IDLE;
    signal py        : unsigned(9 downto 0) := (others => '0');   -- window line prepared
    signal se        : natural range 0 to 127 := 0;               -- entry scanned
    signal nsel      : natural range 0 to 32 := 0;
    signal pixels    : natural range 0 to 1024 := 0;
    signal ovf_next  : std_logic := '0';          -- the prepared line dropped sprites
    signal sel_e     : sel2_t := (others => (others => (others => '0')));
    signal sel_mem   : nib2_t := (others => (others => (others => '0')));
    signal sel_hit   : nib2_t := (others => (others => (others => '0')));
    signal sel_ent   : ent_list := (others => (others => '0'));
    signal sel_r     : row6_t := (others => (others => '0'));
    -- fetching rows into two row buffers
    type fst_t is (F_NEXT, F_BLK, F_DONE);
    signal fst       : fst_t := F_DONE;
    signal fk        : natural range 0 to 32 := 0;                -- sprite whose row is fetched
    signal rdy       : std_logic_vector(1 downto 0) := "00";      -- row buffer filled
    signal rbuf      : rowbuf2_t := (others => (others => (others => '0')));
    signal r_addr    : unsigned(16 downto 0) := (others => '0');  -- row start
    signal r_k       : natural range 0 to 7 := 0;                 -- block of the row
    signal r_off     : off2_t := (others => (others => '0'));     -- row start in its first block
    signal r_len     : natural range 0 to 64 := 0;
    signal r_blk     : unsigned(13 downto 0) := (others => '0');
    signal req_r     : std_logic := '0';
    signal addr_r    : unsigned(13 downto 0) := (others => '0');
    signal waiting   : std_logic := '0';
    signal drop      : std_logic := '0';
    -- drawing
    type dst_t is (D_WAIT, D_DRAW, D_GAP, D_DONE);
    signal dst       : dst_t := D_DONE;
    signal dk        : natural range 0 to 32 := 0;                -- sprite being drawn
    signal di        : natural range 0 to 128 := 0;               -- its pixel
    -- the draw pipeline: address now, buffer data two clocks on, write then
    signal dp1_v, dp2_v : std_logic := '0';
    signal dp1_sx, dp2_sx : natural range 0 to 511 := 0;
    signal dp1_c, dp2_c : std_logic_vector(7 downto 0) := (others => '0');
    signal dp1_beh, dp2_beh : std_logic := '0';
    signal dp1_bit, dp2_bit : natural range 0 to 31 := 0;

    -- display
    signal shown_on  : std_logic := '0';
    signal last_m    : std_logic_vector(31 downto 0) := (others => '0');
    signal sel_cb_bit : unsigned(1 downto 0) := "00";  -- the sel list the shown line uses
    signal sel_nb     : unsigned(1 downto 0) := "01";  -- ... the one being selected

    -- collisions
    signal fifo      : fifo_t := (others => (others => '0'));
    signal f_wp, f_rp : unsigned(7 downto 0) := (others => '0');
    signal fifo_q    : std_logic_vector(33 downto 0) := (others => '0');
    signal fifo_we   : std_logic := '0';
    signal f_wp_d    : unsigned(7 downto 0) := (others => '0');  -- entries in the RAM
    signal fifo_wa   : unsigned(7 downto 0) := (others => '0');
    signal fifo_wd   : std_logic_vector(33 downto 0) := (others => '0');
    signal pairs_we  : std_logic := '0';
    signal pairs_wa  : natural range 0 to 127 := 0;
    signal pairs_wd  : std_logic_vector(15 downto 0) := (others => '0');
    signal pairs_ra  : natural range 0 to 127 := 0;
    signal pairs_q   : std_logic_vector(15 downto 0) := (others => '0');
    signal c_mask    : std_logic_vector(31 downto 0) := (others => '0');
    signal c_cb      : natural range 0 to 3 := 0;
    signal c_e1      : std_logic_vector(7 downto 0) := (others => '0');
    signal c_j       : std_logic_vector(31 downto 0) := (others => '0');
    signal c_row     : std_logic_vector(127 downto 0) := (others => '0');
    type cst_t is (C_IDLE, C_TAKE, C_LOW, C_RD, C_LOAD, C_PAIRS);
    signal cst       : cst_t := C_IDLE;
    signal pairs     : pair_ram := (others => (others => '0'));
    signal pcount    : natural range 0 to 127 := 0;
    signal collfull  : std_logic := '0';
    signal overflow  : std_logic := '0';
    -- pairs seen this frame: row e1, bit e2
    signal seen      : seen_ram := (others => (others => '0'));
    signal seen_ra   : natural range 0 to 127 := 0;
    signal seen_wa   : natural range 0 to 127 := 0;
    signal seen_q    : std_logic_vector(127 downto 0) := (others => '0');
    signal seen_we   : std_logic := '0';
    signal seen_wd   : std_logic_vector(127 downto 0) := (others => '0');

    -- publishing
    type pst_t is (W_IDLE, W_WAIT, W_STAT, W_PAIRS, W_PDATA, W_CLEAR);
    signal pst       : pst_t := W_IDLE;
    signal pi        : natural range 0 to 255 := 0;
    signal preq_r    : std_logic := '0';
    signal paddr_r   : unsigned(11 downto 0) := (others => '0');
    signal pdata_r   : std_logic_vector(7 downto 0) := (others => '0');
    signal irq_r     : std_logic := '0';
    signal clr_i     : natural range 0 to 128 := 128;
    signal pdata_wait : std_logic := '0';

    function lowest(v : std_logic_vector(31 downto 0)) return natural is
    begin
        for i in 0 to 31 loop
            if v(i) = '1' then
                return i;
            end if;
        end loop;
        return 0;
    end function;

    function two_or_more(v : std_logic_vector(31 downto 0)) return boolean is
    begin
        return (v and std_logic_vector(unsigned(v) - 1)) /= x"00000000";
    end function;

begin

    f_req    <= req_r;
    f_busy   <= '1' when st = P_SEL or st = P_SEL2 or fst = F_BLK or req_r = '1' or waiting = '1' or
                         (fst = F_NEXT and fk < nsel) else '0';
    f_addr   <= addr_r;
    p_req    <= preq_r;
    p_addr   <= paddr_r;
    p_data   <= pdata_r;
    coll_irq <= irq_r;

    ---------------------------------------------------------------------------
    -- the table

    live_mem : for l in 0 to 7 generate
        signal lane : byte_ram := (others => (others => '0'));
    begin
        process (clk)
        begin
            if rising_edge(clk) then
                if tw_we = '1' and to_integer(tw_addr(2 downto 0)) = l then
                    lane(to_integer(tw_addr(9 downto 3))) <= tw_data;
                end if;
                lat_rd(8 * l + 7 downto 8 * l) <= lane(lat_ra);
            end if;
        end process;
    end generate;

    lat_mem : process (clk)
    begin
        if rising_edge(clk) then
            if lat_v = '1' then
                latched(lat_k) <= lat_rd;
            end if;
            ent_q <= latched(se);
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- line buffers

    we0 <= d_we when draw_b = '0' else s_we;
    wa0 <= d_wa when draw_b = '0' else s_wa;
    wd0 <= d_wd when draw_b = '0' else (others => '0');
    ra0 <= d_ra when draw_b = '0' else s_ra;
    we1 <= s_we when draw_b = '0' else d_we;
    wa1 <= s_wa when draw_b = '0' else d_wa;
    wd1 <= (others => '0') when draw_b = '0' else d_wd;
    ra1 <= s_ra when draw_b = '0' else d_ra;

    buf0_mem : process (clk)
    begin
        if rising_edge(clk) then
            if we0 = '1' then
                buf0(wa0) <= wd0;
            end if;
            q0 <= buf0(ra0);
        end if;
    end process;

    buf1_mem : process (clk)
    begin
        if rising_edge(clk) then
            if we1 = '1' then
                buf1(wa1) <= wd1;
            end if;
            q1 <= buf1(ra1);
        end if;
    end process;

    d_q  <= q0 when draw_b = '0' else q1;
    s_q  <= q1 when draw_b = '0' else q0;
    s_ra <= to_integer(x);

    fifo_mem : process (clk)
    begin
        if rising_edge(clk) then
            if fifo_we = '1' then
                fifo(to_integer(fifo_wa)) <= fifo_wd;
            end if;
            fifo_q <= fifo(to_integer(f_rp));
        end if;
    end process;

    pairs_mem : process (clk)
    begin
        if rising_edge(clk) then
            if pairs_we = '1' then
                pairs(pairs_wa) <= pairs_wd;
            end if;
            pairs_q <= pairs(pairs_ra);
        end if;
    end process;

    seen_mem : process (clk)
    begin
        if rising_edge(clk) then
            if seen_we = '1' then
                seen(seen_wa) <= seen_wd;
            end if;
            seen_q <= seen(seen_ra);
        end if;
    end process;

    ---------------------------------------------------------------------------

    main : process (clk)
        variable e      : std_logic_vector(63 downto 0);
        variable h, w, sw, row, rl : natural range 0 to 128;
        variable yv     : unsigned(9 downto 0);
        variable rowv   : unsigned(9 downto 0);
        variable got    : boolean;
        variable dat    : std_logic_vector(63 downto 0);
        variable o      : integer range -128 to 128;
        variable last   : unsigned(16 downto 0);
        variable ra     : unsigned(21 downto 0);
        variable sx     : unsigned(9 downto 0);
        variable px     : natural range 0 to 127;
        variable c      : std_logic_vector(7 downto 0);
        variable b      : std_logic_vector(7 downto 0);
        variable cur    : std_logic_vector(47 downto 0);
        variable m      : std_logic_vector(31 downto 0);
        variable jm     : std_logic_vector(31 downto 0);
        variable i, j   : natural range 0 to 31;
        variable e2     : natural range 0 to 127;
        variable cb     : natural range 0 to 3;
        variable nb     : natural range 0 to 3;
        variable rw     : std_logic_vector(127 downto 0);
        variable stop   : boolean;
        variable slot   : natural range 0 to 1;
        variable bpos   : natural range 0 to 127;
    begin
        if rising_edge(clk) then
            d_we    <= '0';
            s_we    <= '0';
            seen_we <= '0';
            fifo_we <= '0';
            pairs_we <= '0';
            f_wp_d  <= f_wp;
            irq_r   <= '0';
            lat_v   <= '0';
            got     := false;

            -- latch the table at the start of each frame: lane read at
            -- lat_ra, written to entry lat_k the clock after
            if frame_start = '1' then
                lat_busy <= '1';
                lat_ra   <= 0;
            elsif lat_busy = '1' then
                lat_v <= '1';
                lat_k <= lat_ra;
                if lat_ra = 127 then
                    lat_busy <= '0';
                else
                    lat_ra <= lat_ra + 1;
                end if;
            end if;

            -- fetches
            if f_gnt = '1' then
                req_r   <= '0';
                waiting <= '1';
            end if;
            if f_valid = '1' then
                waiting <= '0';
                if drop = '1' then
                    drop <= '0';
                else
                    got := true;
                    dat := f_data;
                end if;
            end if;

            -- the draw pipeline: buffer data for the pixel addressed two
            -- clocks ago is in d_q now; write it back with this sprite
            if dp2_v = '1' then
                cur := d_q;
                if dp2_beh = '1' then
                    if cur(15 downto 8) = x"00" then cur(15 downto 8) := dp2_c; end if;
                else
                    if cur(7 downto 0) = x"00" then cur(7 downto 0) := dp2_c; end if;
                end if;
                cur(16 + dp2_bit) := '1';
                d_we <= '1';
                d_wa <= dp2_sx;
                d_wd <= cur;
            end if;
            dp2_v   <= dp1_v;
            dp2_sx  <= dp1_sx;
            dp2_c   <= dp1_c;
            dp2_beh <= dp1_beh;
            dp2_bit <= dp1_bit;
            dp1_v   <= '0';

            nb := to_integer(sel_nb);

            -- selection
            case st is
                when P_IDLE | P_RUN =>
                    null;

                when P_SEL =>
                    st <= P_SEL2;                   -- entry se comes next clock

                when P_SEL2 =>
                    e := ent_q;
                    stop := se = 127;
                    -- +0 X low, +1 X high/sizes/flips, +2 Y low, +3 Y high/on/behind/groups
                    if e(26) = '1' then
                        h := 8 * 2 ** to_integer(unsigned(e(13 downto 12)));
                        yv := unsigned(e(25 downto 24)) & unsigned(e(23 downto 16));
                        rowv := py - yv;                                     -- wraps at 1024
                        if to_integer(rowv) < h then
                            w  := 8 * 2 ** to_integer(unsigned(e(11 downto 10)));
                            sw := w;
                            if e(53) = '1' then sw := 2 * w; end if;
                            if nsel >= 32 or pixels + sw > 640 then
                                ovf_next <= '1';
                                stop := true;                                -- the rest drop out
                            else
                                pixels <= pixels + sw;
                                sel_ent(nsel) <= e;
                                sel_r(nsel) <= rowv(5 downto 0);
                                sel_e(nb)(nsel) <= std_logic_vector(to_unsigned(se, 8));
                                sel_mem(nb)(nsel) <= e(31 downto 28);
                                if e(59 downto 56) /= "0000" then
                                    sel_hit(nb)(nsel) <= e(59 downto 56);
                                else
                                    sel_hit(nb)(nsel) <= e(31 downto 28);
                                end if;
                                nsel <= nsel + 1;
                            end if;
                        end if;
                    end if;
                    if stop then
                        fk  <= 0;
                        fst <= F_NEXT;
                        dk  <= 0;
                        dst <= D_WAIT;
                        st  <= P_RUN;
                    else
                        se <= se + 1;
                        st <= P_SEL;
                    end if;
            end case;

            -- fetching: rows of the selected sprites into the two row buffers
            slot := fk mod 2;
            case fst is
                when F_DONE =>
                    null;
                when F_NEXT =>
                    if fk >= nsel then
                        fst <= F_DONE;
                    elsif rdy(slot) = '0' then
                        e := sel_ent(fk);
                        h := 8 * 2 ** to_integer(unsigned(e(13 downto 12)));
                        w := 8 * 2 ** to_integer(unsigned(e(11 downto 10)));
                        row := to_integer(sel_r(fk));
                        if e(15) = '1' then row := h - 1 - row; end if;    -- flip Y
                        if e(52) = '1' then rl := w; else rl := w / 2; end if;
                        ra := shift_left(resize(unsigned(e(47 downto 32)), 22), 5) +
                              to_unsigned(row * rl, 22);
                        r_addr <= ra(16 downto 0);
                        r_k    <= 0;
                        r_off(slot) <= ra(2 downto 0);
                        r_blk  <= ra(16 downto 3);
                        r_len  <= rl;
                        fst    <= F_BLK;
                    end if;
                when F_BLK =>
                    if got then
                        rbuf(slot)(r_k) <= dat;
                        if r_k < 7 then
                            r_k <= r_k + 1;
                        end if;
                        last := r_addr + to_unsigned(r_len - 1, 17);
                        if addr_r = last(16 downto 3) then
                            rdy(slot) <= '1';
                            fk  <= fk + 1;
                            fst <= F_NEXT;
                        else
                            r_blk <= addr_r + 1;
                        end if;
                    elsif waiting = '0' and req_r = '0' and f_gnt = '0' then
                        addr_r <= r_blk;
                        req_r  <= '1';
                    end if;
            end case;

            -- drawing, from the row buffers in order
            slot := dk mod 2;
            case dst is
                when D_DONE =>
                    null;
                when D_WAIT =>
                    if dk >= nsel and st = P_RUN then
                        dst <= D_DONE;
                    elsif rdy(slot) = '1' then
                        di  <= 0;
                        dst <= D_DRAW;
                    end if;
                when D_DRAW =>
                    e := sel_ent(dk);
                    w := 8 * 2 ** to_integer(unsigned(e(11 downto 10)));
                    sw := w;
                    if e(53) = '1' then sw := 2 * w; end if;
                    if di >= sw then
                        rdy(slot) <= '0';
                        dst <= D_GAP;
                    else
                        sx := (unsigned(e(9 downto 8)) & unsigned(e(7 downto 0))) + to_unsigned(di, 10);
                        if e(53) = '1' then px := di / 2; else px := di; end if;
                        if e(14) = '1' then px := w - 1 - px; end if;       -- flip X
                        if e(52) = '1' then
                            bpos := to_integer(r_off(slot)) + px;
                            c := rbuf(slot)(bpos / 8)(8 * (bpos mod 8) + 7 downto 8 * (bpos mod 8));
                        else
                            bpos := to_integer(r_off(slot)) + px / 2;
                            b := rbuf(slot)(bpos / 8)(8 * (bpos mod 8) + 7 downto 8 * (bpos mod 8));
                            if px mod 2 = 0 then
                                c := x"0" & b(7 downto 4);
                            else
                                c := x"0" & b(3 downto 0);
                            end if;
                            if c /= x"00" then
                                c := e(51 downto 48) & c(3 downto 0);
                            end if;
                        end if;
                        if to_integer(sx) < l_width and c /= x"00" then
                            d_ra    <= to_integer(sx);
                            dp1_v   <= '1';
                            dp1_sx  <= to_integer(sx);
                            dp1_c   <= c;
                            dp1_beh <= e(27);
                            dp1_bit <= dk;
                        end if;
                        di <= di + 1;
                    end if;
                when D_GAP =>
                    -- the last pixel is written before the next sprite can
                    -- read the same place
                    if dp1_v = '0' and dp2_v = '0' then
                        dk  <= dk + 1;
                        dst <= D_WAIT;
                    end if;
            end case;

            -- display: pixel x is shown this clock; clear it, and queue its
            -- mask for the collision check (unless the pixel before had the
            -- same sprites)
            if x_done = '1' then
                s_we <= '1';
                s_wa <= to_integer(x);
                m := s_q(47 downto 16);
                if shown_on = '1' and two_or_more(m) and m /= last_m and f_wp + 1 /= f_rp then
                    fifo_we <= '1';
                    fifo_wd <= std_logic_vector(sel_cb_bit) & m;
                    fifo_wa <= f_wp;
                    f_wp <= f_wp + 1;
                end if;
                last_m <= m;
            end if;

            -- collisions: the pairs at each queued pixel, one a clock
            case cst is
                when C_IDLE =>
                    if f_rp /= f_wp_d then
                        cst <= C_TAKE;                      -- the entry comes next clock
                    end if;
                when C_TAKE =>
                    c_mask <= fifo_q(31 downto 0);
                    c_cb   <= to_integer(unsigned(fifo_q(33 downto 32)));
                    f_rp   <= f_rp + 1;
                    -- a pixel from three lines back: its list is being
                    -- reused for the next line, so it is dropped
                    if unsigned(fifo_q(33 downto 32)) /= sel_nb then
                        cst <= C_LOW;
                    else
                        cst <= C_IDLE;
                    end if;
                when C_LOW =>
                    -- the lowest sprite left, and those above it that it meets
                    m  := c_mask;
                    cb := c_cb;
                    if collfull = '1' or not two_or_more(m) then
                        cst <= C_IDLE;      -- nothing more this pixel can change
                    else
                        i := lowest(m);
                        jm := (others => '0');
                        for k in 0 to 31 loop
                            if k > i and m(k) = '1' and
                               ((sel_mem(cb)(i) and sel_hit(cb)(k)) /= "0000" or
                                (sel_mem(cb)(k) and sel_hit(cb)(i)) /= "0000") then
                                jm(k) := '1';
                            end if;
                        end loop;
                        m(i)   := '0';
                        c_mask <= m;
                        if jm /= x"00000000" then
                            c_j     <= jm;
                            c_e1    <= sel_e(cb)(i);
                            seen_ra <= to_integer(unsigned(sel_e(cb)(i)(6 downto 0)));
                            cst     <= C_RD;
                        end if;
                    end if;
                when C_RD =>
                    cst <= C_LOAD;                          -- the seen row comes
                when C_LOAD =>
                    c_row <= seen_q;
                    cst   <= C_PAIRS;
                when C_PAIRS =>
                    cb := c_cb;
                    rw := c_row;
                    jm := c_j;
                    j  := lowest(jm);
                    e2 := to_integer(unsigned(sel_e(cb)(j)(6 downto 0)));
                    if rw(e2) = '0' then
                        rw(e2) := '1';
                        if pcount >= 127 then
                            collfull <= '1';
                        else
                            pairs_we <= '1';
                            pairs_wa <= pcount;
                            pairs_wd <= c_e1 & sel_e(cb)(j);
                            pcount <= pcount + 1;
                        end if;
                    end if;
                    jm(j) := '0';
                    c_row <= rw;
                    c_j   <= jm;
                    if jm = x"00000000" then
                        seen_we <= '1';
                        seen_wa <= to_integer(unsigned(c_e1(6 downto 0)));
                        seen_wd <= rw;
                        cst     <= C_LOW;
                    end if;
            end case;

            -- line start: the prepared line becomes the shown one, and the
            -- next one is prepared
            if line_start = '1' then
                shown_on <= '0';
                if raster_y >= win_first and raster_y <= win_last then
                    shown_on <= line_on;
                    if line_on = '1' and ovf_next = '1' then
                        overflow <= '1';
                    end if;
                end if;
                draw_b   <= not draw_b;
                sel_cb_bit <= sel_nb;
                sel_nb     <= sel_nb + 1;
                last_m   <= (others => '0');
                ovf_next <= '0';
                nsel     <= 0;
                pixels   <= 0;
                se       <= 0;
                fk       <= 0;
                dk       <= 0;
                fst      <= F_DONE;
                dst      <= D_DONE;
                rdy      <= "00";
                req_r    <= '0';
                dp1_v    <= '0';
                dp2_v    <= '0';
                d_we     <= '0';
                if (waiting = '1' and f_valid = '0') or f_gnt = '1' then
                    drop <= '1';
                else
                    drop <= '0';
                end if;
                waiting <= waiting and not f_valid;
                if f_gnt = '1' then
                    waiting <= '1';
                end if;
                py <= resize(raster_y, 10) + 1 - resize(win_first, 10);
                l_width <= to_integer(width);
                if raster_y + 1 >= win_first and raster_y + 1 <= win_last then
                    st <= P_SEL;
                else
                    st <= P_IDLE;
                end if;
            end if;

            -- after the window: publish status, count and pairs
            case pst is
                when W_IDLE =>
                    if line_start = '1' and raster_y = win_last + 1 then
                        pst <= W_WAIT;
                    end if;
                when W_WAIT =>
                    if cst = C_IDLE and f_rp = f_wp then
                        preq_r  <= '1';
                        paddr_r <= x"841";
                        pdata_r <= "000000" & collfull & overflow;
                        pi      <= 0;
                        pst     <= W_STAT;
                    end if;
                when W_STAT =>
                    if p_ack = '1' then
                        paddr_r <= x"900";
                        pdata_r <= std_logic_vector(to_unsigned(pcount, 8));
                        pst     <= W_PAIRS;
                    end if;
                when W_PAIRS =>
                    if p_ack = '1' then
                        if pi >= 2 * pcount then
                            preq_r <= '0';
                            if pcount > 0 then
                                irq_r <= '1';
                            end if;
                            pcount   <= 0;
                            collfull <= '0';
                            overflow <= '0';
                            clr_i    <= 0;
                            pst      <= W_CLEAR;
                        else
                            preq_r   <= '0';            -- the pair comes next clock
                            pairs_ra <= pi / 2;
                            pst      <= W_PDATA;
                        end if;
                    end if;
                when W_PDATA =>
                    if preq_r = '0' and pdata_wait = '0' then
                        pdata_wait <= '1';          -- pairs_q follows pairs_ra
                    else
                        pdata_wait <= '0';
                        paddr_r <= to_unsigned(16#901# + pi, 12);
                        if pi mod 2 = 0 then
                            pdata_r <= pairs_q(15 downto 8);
                        else
                            pdata_r <= pairs_q(7 downto 0);
                        end if;
                        pi     <= pi + 1;
                        preq_r <= '1';
                        pst    <= W_PAIRS;
                    end if;
                when W_CLEAR =>
                    -- forget the pairs seen this frame
                    if clr_i < 128 then
                        seen_wa <= clr_i;
                        seen_wd <= (others => '0');
                        seen_we <= '1';
                        clr_i   <= clr_i + 1;
                    else
                        pst <= W_IDLE;
                    end if;
            end case;

            if reset = '1' then
                st       <= P_IDLE;
                fst      <= F_DONE;
                dst      <= D_DONE;
                cst      <= C_IDLE;
                pst      <= W_IDLE;
                preq_r   <= '0';
                req_r    <= '0';
                pcount   <= 0;
                collfull <= '0';
                overflow <= '0';
                f_rp     <= f_wp;
                drop     <= waiting;
            end if;
        end if;
    end process;

    q_front  <= s_q(7 downto 0);
    q_behind <= s_q(15 downto 8);

end architecture;
