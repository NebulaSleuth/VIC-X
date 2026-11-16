-- VIC-X layer: one tile or bitmap layer, for one raster line at a time.
--
-- At line_start the layer takes its setup (the 15 bytes at $20800/$20820 as
-- last written) and the window line, and fetches what the line shows, in
-- 8-byte VRAM blocks through f_req / f_addr: held until f_gnt, then the
-- block comes with f_valid.  Each block is decoded into palette indices
-- (0 = transparent) in a line buffer of 8-pixel words, in order, so the
-- display can read a word as soon as it has been written.
--
-- Bitmaps: the row's blocks, word k from block k (8-bit) or words 2k and
-- 2k+1 (4-bit).  Tiles: for each tile the line crosses, its map entry
-- (from a one-block map cache) and then its row (1 to 3 blocks), decoded
-- with flips and bank into one word (8 wide) or two (16 wide).
--
-- Display: x is the window pixel; two clocks later q_idx / q_ok give its
-- palette index and whether it is opaque, q_late that its word was not
-- there yet.  Follows layer_line in the VICE fork (src/vicx/vicx.c).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity vicx_layer is
    generic (
        HAS_TILES : boolean := true;
        HAS_BMP   : boolean := true
    );
    port (
        clk        : in  std_logic;
        reset      : in  std_logic;

        line_start : in  std_logic;
        enable     : in  std_logic;                        -- CTRL bit, this line
        win_y      : in  unsigned(8 downto 0);             -- window line
        in_win     : in  std_logic;                        -- the line is in the window
        setup      : in  std_logic_vector(119 downto 0);   -- bytes 0-14, byte n at 8n

        f_req      : out std_logic;
        f_addr     : out unsigned(13 downto 0);            -- VRAM block (address / 8)
        f_gnt      : in  std_logic;
        f_valid    : in  std_logic;
        f_data     : in  std_logic_vector(63 downto 0);

        x          : in  unsigned(8 downto 0);
        q_idx      : out std_logic_vector(7 downto 0);
        q_ok       : out std_logic;
        q_late     : out std_logic
    );
end entity;

architecture rtl of vicx_layer is

    type st_t is (S_IDLE, S_BMP, S_ENTRY, S_ROW, S_WRITE, S_DONE);
    type row_t is array (0 to 15) of std_logic_vector(7 downto 0);
    type pbuf_t is array (0 to 63) of std_logic_vector(63 downto 0);

    function sbyte(s : std_logic_vector(119 downto 0); n : natural) return std_logic_vector is
        variable r : std_logic_vector(7 downto 0);
    begin
        r := s(8 * n + 7 downto 8 * n);
        return r;
    end function;

    signal st        : st_t := S_IDLE;
    signal waiting   : std_logic := '0';   -- a granted block is on its way
    signal drop      : std_logic := '0';   -- ... for a line that has ended
    signal req_r     : std_logic := '0';
    signal addr_r    : unsigned(13 downto 0) := (others => '0');

    -- this line's setup
    signal l_on      : std_logic := '0';
    signal l_bmp     : std_logic := '0';
    signal l_m8      : std_logic := '0';
    signal l_big     : std_logic := '0';   -- 16x16 tiles
    signal l_dw      : std_logic := '0';
    signal l_bank    : std_logic_vector(3 downto 0) := (others => '0');
    signal l_off     : unsigned(4 downto 0) := (others => '0');    -- display offset
    signal l_n       : natural range 0 to 64 := 0;     -- blocks (bitmap) or tiles
    signal l_blk0    : unsigned(13 downto 0) := (others => '0');
    signal l_mrow    : unsigned(16 downto 0) := (others => '0');    -- map row start
    signal l_tx0     : unsigned(7 downto 0) := (others => '0');
    signal l_mapw    : unsigned(8 downto 0) := (others => '0');     -- tiles, 32-256
    signal l_tbase   : unsigned(16 downto 0) := (others => '0');
    signal l_py      : unsigned(3 downto 0) := (others => '0');     -- row in the tile

    signal k         : natural range 0 to 64 := 0;     -- block or tile in hand
    signal words     : natural range 0 to 64 := 0;     -- words in the buffer
    signal words_d   : natural range 0 to 64 := 0;
    signal words_dd  : natural range 0 to 64 := 0;

    -- tiles
    signal mc_valid  : std_logic := '0';               -- map cache
    signal mc_blk    : unsigned(13 downto 0) := (others => '0');
    signal mc_data   : std_logic_vector(63 downto 0) := (others => '0');
    signal ent_half  : std_logic := '0';               -- next entry byte: 0 low, 1 high
    signal entry     : std_logic_vector(15 downto 0) := (others => '0');
    signal trow      : unsigned(16 downto 0) := (others => '0');
    signal rlen      : natural range 0 to 16 := 0;
    signal rblk      : unsigned(13 downto 0) := (others => '0');
    signal rbuf      : row_t := (others => (others => '0'));

    -- line buffer
    signal pbuf      : pbuf_t := (others => (others => '0'));
    signal pb_we     : std_logic := '0';
    signal pb_wa     : unsigned(5 downto 0) := (others => '0');
    signal pb_wd     : std_logic_vector(63 downto 0) := (others => '0');
    signal pb_we2    : std_logic := '0';               -- second word of a 16-wide row
    signal pb_wd2    : std_logic_vector(63 downto 0) := (others => '0');
    signal pb_ra     : unsigned(5 downto 0);
    signal pb_q      : std_logic_vector(63 downto 0) := (others => '0');

    -- display
    signal pos       : unsigned(9 downto 0);
    signal a_sel     : unsigned(2 downto 0) := (others => '0');
    signal a_ok      : std_logic := '0';
    signal a_late    : std_logic := '0';
    signal idx_c     : std_logic_vector(7 downto 0);

    -- a 4-bit pixel: bank * 16 + n, or 0
    function nib(bank : std_logic_vector(3 downto 0); n : std_logic_vector(3 downto 0))
        return std_logic_vector is
    begin
        if n = "0000" then
            return x"00";
        end if;
        return bank & n;
    end function;

begin

    f_req  <= req_r;
    f_addr <= addr_r;

    -- line buffer: one write port (two words over two clocks), one read port
    pb_mem : process (clk)
    begin
        if rising_edge(clk) then
            if pb_we = '1' then
                pbuf(to_integer(pb_wa)) <= pb_wd;
            elsif pb_we2 = '1' then
                pbuf(to_integer(pb_wa)) <= pb_wd2;
            end if;
            pb_q <= pbuf(to_integer(pb_ra));
        end if;
    end process;

    fetch : process (clk)
        variable ea      : unsigned(16 downto 0);
        variable eb      : std_logic_vector(7 downto 0);
        variable ent     : std_logic_vector(15 downto 0);
        variable rb      : row_t;
        variable px      : row_t;
        variable o       : integer range -32 to 32;
        variable nb, w   : natural range 0 to 512;
        variable ly      : unsigned(11 downto 0);
        variable lx0     : unsigned(11 downto 0);
        variable tsz     : natural range 8 to 16;
        variable mw, mh  : natural range 32 to 256;
        variable row     : unsigned(18 downto 0);
        variable num     : unsigned(9 downto 0);
        variable prow    : unsigned(3 downto 0);
        variable rl      : natural range 0 to 16;
        variable wv, wv2 : std_logic_vector(63 downto 0);
        variable mode    : std_logic_vector(7 downto 0);
        variable sx, sy  : unsigned(11 downto 0);
        variable got     : boolean;
        variable dat     : std_logic_vector(63 downto 0);
        variable wd      : natural range 0 to 64;
    begin
        if rising_edge(clk) then
            pb_we  <= '0';
            pb_we2 <= '0';
            got    := false;
            wd     := words;

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

            -- the second word of a 16-wide tile row goes in the clock after the first
            if st = S_WRITE then
                pb_we2 <= '1';
                pb_wa  <= pb_wa + 1;
                wd     := wd + 1;
                if k + 1 = l_n then
                    st <= S_DONE;
                elsif l_bmp = '1' then
                    k  <= k + 1;
                    st <= S_BMP;
                else
                    k  <= k + 1;
                    st <= S_ENTRY;
                end if;
            end if;

            case st is
                when S_BMP =>
                    if got then
                        if l_m8 = '1' then
                            pb_we <= '1';
                            pb_wa <= to_unsigned(k, 6);
                            pb_wd <= dat;
                            wd    := wd + 1;
                        else
                            -- 4-bit: 16 pixels, two words, high nibble first
                            for i in 0 to 7 loop
                                eb := dat(8 * i + 7 downto 8 * i);
                                if i < 4 then
                                    wv(16 * i + 7 downto 16 * i)     := nib(l_bank, eb(7 downto 4));
                                    wv(16 * i + 15 downto 16 * i + 8) := nib(l_bank, eb(3 downto 0));
                                else
                                    wv2(16 * (i - 4) + 7 downto 16 * (i - 4))     := nib(l_bank, eb(7 downto 4));
                                    wv2(16 * (i - 4) + 15 downto 16 * (i - 4) + 8) := nib(l_bank, eb(3 downto 0));
                                end if;
                            end loop;
                            pb_we  <= '1';
                            pb_wa  <= to_unsigned(2 * k, 6);
                            pb_wd  <= wv;
                            pb_wd2 <= wv2;
                            wd     := wd + 1;
                        end if;
                        if l_m8 = '0' then
                            -- the second word next clock, then on
                            st <= S_WRITE;
                        elsif k + 1 = l_n then
                            st <= S_DONE;
                        else
                            k <= k + 1;
                        end if;
                    elsif waiting = '0' and req_r = '0' and f_gnt = '0' then
                        addr_r <= l_blk0 + to_unsigned(k, 14);
                        req_r  <= '1';
                    end if;

                when S_ENTRY =>
                    -- map entry for tile k: low byte, then high byte, from the cache
                    if got then
                        mc_blk   <= addr_r;
                        mc_data  <= dat;
                        mc_valid <= '1';
                    else
                        ea := l_mrow + resize(((l_tx0 + to_unsigned(k, 8)) and
                                               resize(l_mapw - 1, 8)) & '0', 17);
                        if ent_half = '1' then
                            ea := ea + 1;
                        end if;
                        if mc_valid = '1' and mc_blk = ea(16 downto 3) then
                            eb := mc_data(8 * to_integer(ea(2 downto 0)) + 7 downto 8 * to_integer(ea(2 downto 0)));
                            if ent_half = '0' then
                                entry(7 downto 0) <= eb;
                                ent_half <= '1';
                            else
                                ent := eb & entry(7 downto 0);
                                entry    <= ent;
                                ent_half <= '0';
                                -- the tile's row: where it starts and how long it is
                                if l_big = '1' then tsz := 16; else tsz := 8; end if;
                                prow := l_py;
                                if ent(11) = '1' then
                                    prow := to_unsigned(tsz - 1, 4) - l_py;
                                end if;
                                num := unsigned(ent(9 downto 0));
                                if l_m8 = '1' then
                                    rl := tsz;
                                    if l_big = '1' then
                                        row := resize(l_tbase, 19) + shift_left(resize(num, 19), 8)
                                               + shift_left(resize(prow, 19), 4);
                                    else
                                        row := resize(l_tbase, 19) + shift_left(resize(num, 19), 6)
                                               + shift_left(resize(prow, 19), 3);
                                    end if;
                                else
                                    rl := tsz / 2;
                                    if l_big = '1' then
                                        row := resize(l_tbase, 19) + shift_left(resize(num, 19), 7)
                                               + shift_left(resize(prow, 19), 3);
                                    else
                                        row := resize(l_tbase, 19) + shift_left(resize(num, 19), 5)
                                               + shift_left(resize(prow, 19), 2);
                                    end if;
                                end if;
                                trow <= row(16 downto 0);
                                rlen <= rl;
                                rblk <= row(16 downto 3);
                                st   <= S_ROW;
                            end if;
                        elsif waiting = '0' and req_r = '0' and f_gnt = '0' then
                            addr_r <= ea(16 downto 3);
                            req_r  <= '1';
                        end if;
                    end if;

                when S_ROW =>
                    -- the row's blocks, gathered into rbuf
                    if got then
                        rb := rbuf;
                        for n in 0 to 7 loop
                            o := to_integer(addr_r & to_unsigned(n, 3)) - to_integer(trow);
                            if o >= 0 and o < rlen then
                                rb(o) := dat(8 * n + 7 downto 8 * n);
                            end if;
                        end loop;
                        rbuf <= rb;
                        ea := trow + to_unsigned(rlen - 1, 17);     -- the row's last byte
                        if addr_r = ea(16 downto 3) then
                            -- the whole row: decode it
                            if l_big = '1' then tsz := 16; else tsz := 8; end if;
                            for i in 0 to 15 loop
                                if l_m8 = '1' then
                                    px(i) := rb(i);
                                elsif i mod 2 = 0 then
                                    px(i) := nib(entry(15 downto 12), rb(i / 2)(7 downto 4));
                                else
                                    px(i) := nib(entry(15 downto 12), rb(i / 2)(3 downto 0));
                                end if;
                            end loop;
                            if entry(10) = '1' then         -- flip X
                                rb := px;
                                for i in 0 to 15 loop
                                    if i < tsz then
                                        px(i) := rb(tsz - 1 - i);
                                    end if;
                                end loop;
                            end if;
                            for i in 0 to 7 loop
                                wv(8 * i + 7 downto 8 * i)  := px(i);
                                wv2(8 * i + 7 downto 8 * i) := px(i + 8);
                            end loop;
                            pb_we <= '1';
                            pb_wd <= wv;
                            pb_wd2 <= wv2;
                            wd    := wd + 1;
                            if l_big = '1' then
                                pb_wa <= to_unsigned(2 * k, 6);
                                st    <= S_WRITE;
                            else
                                pb_wa <= to_unsigned(k, 6);
                                if k + 1 = l_n then
                                    st <= S_DONE;
                                else
                                    k  <= k + 1;
                                    st <= S_ENTRY;
                                end if;
                            end if;
                        else
                            rblk <= addr_r + 1;
                        end if;
                    elsif waiting = '0' and req_r = '0' and f_gnt = '0' then
                        addr_r <= rblk;
                        req_r  <= '1';
                    end if;

                when others =>
                    null;
            end case;

            -- start of a line: what this line shows, and from where
            if line_start = '1' then
                mode := sbyte(setup, 0);
                sx := unsigned(sbyte(setup, 9)(3 downto 0)) & unsigned(sbyte(setup, 8));
                sy := unsigned(sbyte(setup, 11)(3 downto 0)) & unsigned(sbyte(setup, 10));
                l_m8   <= mode(0);
                l_dw   <= mode(3);
                l_big  <= mode(2);
                l_bank <= sbyte(setup, 14)(3 downto 0);
                if mode(0) = '1' then w := 320; else w := 160; end if;
                if mode(3) = '1' then w := w / 2; end if;      -- bitmap bytes
                k        <= 0;
                wd       := 0;
                mc_valid <= '0';
                ent_half <= '0';
                req_r    <= '0';
                -- a block still to come belongs to the line that ended
                if (waiting = '1' and f_valid = '0') or f_gnt = '1' then
                    drop <= '1';
                else
                    drop <= '0';
                end if;
                waiting <= waiting and not f_valid;
                if f_gnt = '1' then
                    waiting <= '1';
                end if;
                if enable = '1' and in_win = '1' and mode(1) = '1' and HAS_BMP then
                    -- bitmap: base + y * stride
                    row := resize(unsigned(sbyte(setup, 4)(0 downto 0)) & unsigned(sbyte(setup, 3)) &
                                  unsigned(sbyte(setup, 2)), 19) +
                           resize(win_y(7 downto 0) * (unsigned(sbyte(setup, 13)(2 downto 0)) &
                                                       unsigned(sbyte(setup, 12))), 19);
                    l_on   <= '1';
                    l_bmp  <= '1';
                    l_blk0 <= row(16 downto 3);
                    l_n    <= (to_integer(row(2 downto 0)) + w + 7) / 8;
                    if mode(0) = '1' then
                        l_off <= resize(row(2 downto 0), 5);
                    else
                        l_off <= resize(row(2 downto 0) & '0', 5);
                    end if;
                    st <= S_BMP;
                elsif enable = '1' and in_win = '1' and mode(1) = '0' and HAS_TILES then
                    if mode(2) = '1' then tsz := 16; else tsz := 8; end if;
                    mw := 32 * 2 ** to_integer(unsigned(sbyte(setup, 1)(1 downto 0)));
                    mh := 32 * 2 ** to_integer(unsigned(sbyte(setup, 1)(3 downto 2)));
                    if mode(3) = '1' then nb := 160; else nb := 320; end if;   -- layer pixels
                    ly  := (resize(win_y, 12) + sy) and to_unsigned(mh * tsz - 1, 12);
                    lx0 := sx and to_unsigned(mw * tsz - 1, 12);
                    l_on   <= '1';
                    l_bmp  <= '0';
                    l_mapw <= to_unsigned(mw, 9);
                    l_tbase <= unsigned(sbyte(setup, 7)(0 downto 0)) & unsigned(sbyte(setup, 6)) &
                               unsigned(sbyte(setup, 5));
                    if tsz = 16 then
                        l_py  <= ly(3 downto 0);
                        l_tx0 <= lx0(11 downto 4);
                        l_off <= resize(lx0(3 downto 0), 5);
                        l_n   <= (to_integer(lx0(3 downto 0)) + nb + 15) / 16;
                        row := resize(unsigned(sbyte(setup, 4)(0 downto 0)) & unsigned(sbyte(setup, 3)) &
                                      unsigned(sbyte(setup, 2)), 19) +
                               resize(ly(11 downto 4) * to_unsigned(mw * 2, 10), 19);
                    else
                        l_py  <= '0' & ly(2 downto 0);
                        l_tx0 <= lx0(10 downto 3);
                        l_off <= resize(lx0(2 downto 0), 5);
                        l_n   <= (to_integer(lx0(2 downto 0)) + nb + 7) / 8;
                        row := resize(unsigned(sbyte(setup, 4)(0 downto 0)) & unsigned(sbyte(setup, 3)) &
                                      unsigned(sbyte(setup, 2)), 19) +
                               resize(ly(10 downto 3) * to_unsigned(mw * 2, 10), 19);
                    end if;
                    l_mrow <= row(16 downto 0);
                    st <= S_ENTRY;
                else
                    l_on <= '0';
                    st   <= S_IDLE;
                end if;
            end if;

            if reset = '1' then
                st      <= S_IDLE;
                l_on    <= '0';
                req_r   <= '0';
                wd      := 0;
            end if;

            words    <= wd;
            words_d  <= words;
            words_dd <= words_d;
        end if;
    end process;

    -- display: word and byte of window pixel x
    disp_pos : process (x, l_dw, l_off)
        variable lx : unsigned(8 downto 0);
    begin
        lx := x;
        if l_dw = '1' then
            lx := '0' & x(8 downto 1);
        end if;
        pos <= resize(lx, 10) + resize(l_off, 10);
    end process;
    pb_ra <= pos(8 downto 3);

    disp : process (clk)
    begin
        if rising_edge(clk) then
            a_sel  <= pos(2 downto 0);
            a_ok   <= '0';
            a_late <= '0';
            if l_on = '1' then
                if to_integer(pos(9 downto 3)) < words_dd then
                    a_ok <= '1';
                else
                    a_late <= '1';
                end if;
            end if;
        end if;
    end process;

    idx_c  <= pb_q(8 * to_integer(a_sel) + 7 downto 8 * to_integer(a_sel));
    q_idx  <= idx_c;
    q_ok   <= '1' when a_ok = '1' and idx_c /= x"00" else '0';
    q_late <= a_late;

end architecture;
