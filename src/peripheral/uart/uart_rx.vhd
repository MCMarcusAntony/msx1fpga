-------------------------------------------------------------------------------
--
-- MSX1 FPGA project
--
-- Copyright (c) 2016, Fabio Belavenuto (belavenuto@gmail.com)
--
-- All rights reserved
--
-- Redistribution and use in source and synthezised forms, with or without
-- modification, are permitted provided that the following conditions are met:
--
-- Redistributions of source code must retain the above copyright notice,
-- this list of conditions and the following disclaimer.
--
-- Redistributions in synthesized form must reproduce the above copyright
-- notice, this list of conditions and the following disclaimer in the
-- documentation and/or other materials provided with the distribution.
--
-- Neither the name of the author nor the names of other contributors may
-- be used to endorse or promote products derived from this software without
-- specific prior written permission.
--
-- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
-- AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
-- THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
-- PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE
-- LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
-- CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
-- SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
-- INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
-- CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
-- ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
-- POSSIBILITY OF SUCH DAMAGE.
--
-- Please report bugs to the author, but before you do so, please
-- make sure that this is not a derivative work and that
-- you have the latest version of this file.
--
-- RX filter based on work of Grant Searle (bufferedUART.vhd), copyright 2013
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use ieee.numeric_std.all;

entity uart_rx is
	port(
		clock_i		: in  std_logic;
		reset_i		: in  std_logic;
		baud_i		: in  std_logic_vector(15 downto 0);
		char_len_i	: in  std_logic_vector( 1 downto 0);
		stop_bits_i	: in  std_logic;
		parity_i		: in  std_logic_vector( 1 downto 0);
		data_o		: out std_logic_vector( 7 downto 0);
		rx_full_i	: in  std_logic;
		fifo_wr_o	: out std_logic;
		errors_o		: out std_logic_vector( 2 downto 0);
		rx_i			: in  std_logic
	);
end entity;

architecture rcvr of uart_rx is

	type state_t is (stIdle, stStart, stData, stParity, stStop2, stStop1);
	signal state_s			: state_t;
	signal rx_filter_q	: integer range 0 to 10; 
	signal rx_filtered_s	: std_logic								:= '1';
	signal parity_cfg_s	: std_logic_vector(1 downto 0)	:= (others => '0');
	signal stop_bits_s	: std_logic								:= '0';
	signal baudr_cnt_q	: integer range 0 to 65536			:= 0;
	signal max_cnt_s		: integer range 0 to 65536			:= 0;
	signal mid_cnt_s		: integer range 0 to 32768			:= 0;
	signal bit_cnt_q		: integer range 0 to 9				:= 0;
	signal bitmax_s		: unsigned(3 downto 0)				:= (others => '0');
	signal shift_q			: std_logic_vector(7 downto 0)	:= (others => '0');
	signal parity_s		: std_logic;

begin

	parity_s		<= parity_i(1) xor shift_q(7) xor shift_q(6) xor
						shift_q(5) xor shift_q(4) xor shift_q(3) xor
						shift_q(2) xor shift_q(1) xor shift_q(0);


	-- RX de-glitcher - important because the FPGA is very sensistive
	-- Filtered RX will not switch low to high until there is 10 more high samples than lows
	-- hysteresis will then not switch high to low until there is 10 more low samples than highs.
	-- Introduces a minor delay
	-- However, then makes serial comms 100% reliable
	process (clock_i)
	begin
		if falling_edge(clock_i) then
			if rx_i = '1' and rx_filter_q = 10 then
				rx_filtered_s <= '1';
			end if;
			if rx_i = '1' and rx_filter_q /= 10 then
				rx_filter_q <= rx_filter_q+1;
			end if;
			if rx_i = '0' and rx_filter_q = 0 then
				rx_filtered_s <= '0';
			end if;
			if rx_i = '0' and rx_filter_q /= 0 then
				rx_filter_q <= rx_filter_q-1;
			end if;
		end if;
	end process;

	-- Main process
	process(clock_i)
	begin
		if rising_edge(clock_i) then

			if reset_i = '1' then
				parity_cfg_s	<= (others => '0');
				stop_bits_s		<= '0';
				baudr_cnt_q		<= 0;
				shift_q			<= (others => '0');
				bit_cnt_q		<= 0;
				state_s			<= stIdle;
				fifo_wr_o		<= '0';
				errors_o			<= (others => '0');
			else

				fifo_wr_o	<= '0';
				errors_o		<= (others => '0');

				case state_s is

					when stIdle =>
						if rx_filtered_s = '0' then							-- Start bit detected
							baudr_cnt_q		<= 0;
							bit_cnt_q		<= 0;
							bitmax_s			<= to_unsigned(4, 4) + unsigned(char_len_i);
							max_cnt_s		<= to_integer(unsigned(baud_i));
							mid_cnt_s		<= to_integer(unsigned(baud_i)) / 2;
							parity_cfg_s	<= parity_i;
							stop_bits_s		<= stop_bits_i;
							shift_q			<= (others => '0');
							state_s			<= stStart;
						end if;

					when stStart =>
						if baudr_cnt_q >= mid_cnt_s then
							baudr_cnt_q <= 0;
							state_s		<= stData;
						else
							baudr_cnt_q <= baudr_cnt_q + 1;
						end if;

					when stData =>
						if baudr_cnt_q >= max_cnt_s then
							baudr_cnt_q <= 0;
							shift_q(bit_cnt_q)	<= rx_filtered_s;
							if bit_cnt_q >= bitmax_s then
								if parity_cfg_s /= "00" then
									state_s		<= stParity;
								else
									if stop_bits_s = '0' then
										state_s		<= stStop1;
									else
										state_s		<= stStop2;
									end if;
								end if;
							else
								bit_cnt_q <= bit_cnt_q + 1;
							end if;
						else
							baudr_cnt_q <= baudr_cnt_q + 1;
						end if;

					when stParity =>
						if baudr_cnt_q >= max_cnt_s then
							baudr_cnt_q <= 0;
							if parity_s /= rx_filtered_s then
								errors_o(0)	<= '1';							-- Parity Error
								state_s		<= stIdle;
							elsif stop_bits_s = '0' then
								state_s		<= stStop1;
							else
								state_s		<= stStop2;
							end if;
						else
							baudr_cnt_q <= baudr_cnt_q + 1;
						end if;

					when stStop2 =>
						if baudr_cnt_q >= max_cnt_s then
							baudr_cnt_q <= 0;
							if rx_filtered_s = '0' then
								errors_o(1)	<= '1';							-- Frame error
								state_s		<= stIdle;
							else
								state_s		<= stStop1;
							end if;
						else
							baudr_cnt_q <= baudr_cnt_q + 1;
						end if;

					when stStop1 =>
						if baudr_cnt_q >= max_cnt_s then
							baudr_cnt_q <= 0;
							if rx_filtered_s = '0' then
								errors_o(1)	<= '1';							-- Frame error
								state_s		<= stIdle;
							elsif rx_full_i = '1' then
								errors_o(2)	<= '1';							-- Overrun error
							else
								fifo_wr_o	<= '1';							-- No errors, write data
							end if;
							state_s		<= stIdle;
						else
							baudr_cnt_q <= baudr_cnt_q + 1;
						end if;

				end case;
			end if;
		end if;
	end process;

	data_o	<= shift_q;

end architecture;