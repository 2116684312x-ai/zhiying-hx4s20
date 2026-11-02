


`define   DATA_WIDTH                        32
`define   ADDR_WIDTH                        21
`define   DM_WIDTH                          4

`define   ROW_WIDTH                        11
`define   BA_WIDTH                        2

`define	  SDR_CLK_PERIOD				(1000000000/125000000)
// EM638325 requires 4096 auto-refresh commands per 64 ms. Request at 2x
// that rate so a request delayed by application traffic still has margin.
`define   SELF_REFRESH_INTERVAL            (64000000/`SDR_CLK_PERIOD/4096/2)

