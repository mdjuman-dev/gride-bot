//+------------------------------------------------------------------+
//|                                                TradeObserver.mq5 |
//| Read-only: records every order/deal of the account to CSV files  |
//| in Terminal\Common\Files\Observer. It never sends a trade.       |
//+------------------------------------------------------------------+
#property version     "1.00"
#property description "Read-only trade recorder. Never trades. Works with an investor (read-only) login."

input int InpHistoryDays = 30; // Days of history to save at start
input int InpSnapshotSec = 30; // Seconds between snapshots of open positions/orders

int    g_events   = INVALID_HANDLE;
int    g_snapshot = INVALID_HANDLE;
string g_folder   = "Observer\\";
string g_login    = "";

string Ts(const long msc)
  {
   return TimeToString((datetime)(msc / 1000), TIME_DATE | TIME_SECONDS) + "." + IntegerToString(msc % 1000, 3, '0');
  }

string Px(const double value)
  {
   return DoubleToString(value, _Digits);
  }

long NowMsc()
  {
   MqlTick tick;
   if(SymbolInfoTick(_Symbol, tick) && tick.time_msc > 0)
      return tick.time_msc;
   return (long)TimeTradeServer() * 1000;
  }

// Opens a CSV for appending and writes the header if the file is new.
int OpenAppend(const string name, const string header)
  {
   int h = FileOpen(g_folder + name, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ);
   if(h == INVALID_HANDLE)
     {
      Print("Observer: cannot open ", name, " error ", GetLastError());
      return h;
     }
   if(FileSize(h) == 0)
      FileWriteString(h, header + "\r\n");
   FileSeek(h, 0, SEEK_END);
   return h;
  }

void WriteLine(const int h, const string line)
  {
   if(h == INVALID_HANDLE)
      return;
   FileWriteString(h, line + "\r\n");
   FileFlush(h);
  }

void SaveInfo()
  {
   int h = FileOpen(g_folder + "info_" + g_login + ".txt", FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE)
      return;
   FileWriteString(h, "login=" + g_login + "\r\n");
   FileWriteString(h, "server=" + AccountInfoString(ACCOUNT_SERVER) + "\r\n");
   FileWriteString(h, "company=" + AccountInfoString(ACCOUNT_COMPANY) + "\r\n");
   FileWriteString(h, "currency=" + AccountInfoString(ACCOUNT_CURRENCY) + "\r\n");
   FileWriteString(h, "balance=" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + "\r\n");
   FileWriteString(h, "leverage=" + IntegerToString(AccountInfoInteger(ACCOUNT_LEVERAGE)) + "\r\n");
   FileWriteString(h, "trade_allowed=" + (AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) ? "true" : "false (investor login)") + "\r\n");
   FileWriteString(h, "chart_symbol=" + _Symbol + "\r\n");
   FileWriteString(h, "digits=" + IntegerToString(_Digits) + "\r\n");
   FileWriteString(h, "point=" + DoubleToString(_Point, _Digits) + "\r\n");
   FileWriteString(h, "contract_size=" + DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE), 2) + "\r\n");
   FileWriteString(h, "server_minus_gmt_sec=" + IntegerToString((long)(TimeTradeServer() - TimeGMT())) + "\r\n");
   FileWriteString(h, "saved_at=" + TimeToString(TimeTradeServer(), TIME_DATE | TIME_SECONDS) + "\r\n");
   FileClose(h);
  }

void SaveHistory()
  {
   datetime to = TimeTradeServer() + 86400;
   if(!HistorySelect(to - (InpHistoryDays + 1) * 86400, to))
      return;

   int h = FileOpen(g_folder + "deals_" + g_login + ".csv", FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h != INVALID_HANDLE)
     {
      FileWriteString(h, "time;deal;order;position;symbol;type;entry;volume;price;profit;commission;swap;magic;reason;comment\r\n");
      int total = HistoryDealsTotal();
      for(int i = 0; i < total; i++)
        {
         ulong t = HistoryDealGetTicket(i);
         if(t == 0)
            continue;
         FileWriteString(h, StringFormat("%s;%I64u;%I64d;%I64d;%s;%s;%s;%.2f;%s;%.2f;%.2f;%.2f;%I64d;%s;%s\r\n",
                         Ts(HistoryDealGetInteger(t, DEAL_TIME_MSC)), t,
                         HistoryDealGetInteger(t, DEAL_ORDER), HistoryDealGetInteger(t, DEAL_POSITION_ID),
                         HistoryDealGetString(t, DEAL_SYMBOL),
                         EnumToString((ENUM_DEAL_TYPE)HistoryDealGetInteger(t, DEAL_TYPE)),
                         EnumToString((ENUM_DEAL_ENTRY)HistoryDealGetInteger(t, DEAL_ENTRY)),
                         HistoryDealGetDouble(t, DEAL_VOLUME), Px(HistoryDealGetDouble(t, DEAL_PRICE)),
                         HistoryDealGetDouble(t, DEAL_PROFIT), HistoryDealGetDouble(t, DEAL_COMMISSION),
                         HistoryDealGetDouble(t, DEAL_SWAP), HistoryDealGetInteger(t, DEAL_MAGIC),
                         EnumToString((ENUM_DEAL_REASON)HistoryDealGetInteger(t, DEAL_REASON)),
                         HistoryDealGetString(t, DEAL_COMMENT)));
        }
      FileClose(h);
      Print("Observer: saved ", total, " deals");
     }

   h = FileOpen(g_folder + "orders_" + g_login + ".csv", FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h != INVALID_HANDLE)
     {
      FileWriteString(h, "setup;done;order;position;symbol;type;state;volume;price;sl;tp;magic;reason;comment\r\n");
      int total = HistoryOrdersTotal();
      for(int i = 0; i < total; i++)
        {
         ulong t = HistoryOrderGetTicket(i);
         if(t == 0)
            continue;
         FileWriteString(h, StringFormat("%s;%s;%I64u;%I64d;%s;%s;%s;%.2f;%s;%s;%s;%I64d;%s;%s\r\n",
                         Ts(HistoryOrderGetInteger(t, ORDER_TIME_SETUP_MSC)), Ts(HistoryOrderGetInteger(t, ORDER_TIME_DONE_MSC)),
                         t, HistoryOrderGetInteger(t, ORDER_POSITION_ID),
                         HistoryOrderGetString(t, ORDER_SYMBOL),
                         EnumToString((ENUM_ORDER_TYPE)HistoryOrderGetInteger(t, ORDER_TYPE)),
                         EnumToString((ENUM_ORDER_STATE)HistoryOrderGetInteger(t, ORDER_STATE)),
                         HistoryOrderGetDouble(t, ORDER_VOLUME_INITIAL), Px(HistoryOrderGetDouble(t, ORDER_PRICE_OPEN)),
                         Px(HistoryOrderGetDouble(t, ORDER_SL)), Px(HistoryOrderGetDouble(t, ORDER_TP)),
                         HistoryOrderGetInteger(t, ORDER_MAGIC),
                         EnumToString((ENUM_ORDER_REASON)HistoryOrderGetInteger(t, ORDER_REASON)),
                         HistoryOrderGetString(t, ORDER_COMMENT)));
        }
      FileClose(h);
      Print("Observer: saved ", total, " history orders");
     }
  }

void Snapshot()
  {
   MqlTick tick;
   SymbolInfoTick(_Symbol, tick);
   string now = Ts(NowMsc());
   WriteLine(g_snapshot, StringFormat("%s;ACCOUNT;;;;%s;%s;;%.2f;balance=%.2f equity=%.2f positions=%d orders=%d spread=%s",
                         now, Px(tick.bid), Px(tick.ask), AccountInfoDouble(ACCOUNT_PROFIT),
                         AccountInfoDouble(ACCOUNT_BALANCE), AccountInfoDouble(ACCOUNT_EQUITY),
                         PositionsTotal(), OrdersTotal(), Px(tick.ask - tick.bid)));
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      WriteLine(g_snapshot, StringFormat("%s;POSITION;%I64u;%s;%.2f;%s;%s;%s;%.2f;magic=%I64d %s",
                            now, t, EnumToString((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)),
                            PositionGetDouble(POSITION_VOLUME), Px(PositionGetDouble(POSITION_PRICE_OPEN)),
                            Px(PositionGetDouble(POSITION_SL)), Px(PositionGetDouble(POSITION_TP)),
                            PositionGetDouble(POSITION_PROFIT), PositionGetInteger(POSITION_MAGIC),
                            PositionGetString(POSITION_COMMENT)));
     }
   for(int i = 0; i < OrdersTotal(); i++)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0)
         continue;
      WriteLine(g_snapshot, StringFormat("%s;ORDER;%I64u;%s;%.2f;%s;%s;%s;;magic=%I64d %s",
                            now, t, EnumToString((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE)),
                            OrderGetDouble(ORDER_VOLUME_CURRENT), Px(OrderGetDouble(ORDER_PRICE_OPEN)),
                            Px(OrderGetDouble(ORDER_SL)), Px(OrderGetDouble(ORDER_TP)),
                            OrderGetInteger(ORDER_MAGIC), OrderGetString(ORDER_COMMENT)));
     }
  }

int OnInit()
  {
   g_login = IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   SaveInfo();
   SaveHistory();
   g_events = OpenAppend("events_" + g_login + ".csv",
                         "time;transaction;order;deal;position;symbol;order_type;order_state;deal_type;entry;volume;price;sl;tp;profit;bid;ask;magic;comment");
   g_snapshot = OpenAppend("snapshot_" + g_login + ".csv",
                           "time;kind;ticket;type;volume;price;sl;tp;profit;extra");
   Snapshot();
   EventSetTimer(MathMax(5, InpSnapshotSec));
   Print("Observer: recording account ", g_login, " to Common\\Files\\", g_folder);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_events != INVALID_HANDLE)
      FileClose(g_events);
   if(g_snapshot != INVALID_HANDLE)
      FileClose(g_snapshot);
  }

void OnTimer()
  {
   Snapshot();
  }

void OnTick()
  {
  }

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type == TRADE_TRANSACTION_REQUEST)
      return;
   MqlTick tick;
   SymbolInfoTick(trans.symbol != "" ? trans.symbol : _Symbol, tick);

   string entry = "", comment = "";
   double profit = 0.0;
   long   magic  = 0;
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD && HistoryDealSelect(trans.deal))
     {
      entry   = EnumToString((ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY));
      profit  = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
      magic   = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
      comment = HistoryDealGetString(trans.deal, DEAL_COMMENT);
     }
   else
      if(trans.order != 0 && OrderSelect(trans.order))
        {
         magic   = OrderGetInteger(ORDER_MAGIC);
         comment = OrderGetString(ORDER_COMMENT);
        }

   WriteLine(g_events, StringFormat("%s;%s;%I64u;%I64u;%I64u;%s;%s;%s;%s;%s;%.2f;%s;%s;%s;%.2f;%s;%s;%I64d;%s",
                       Ts(tick.time_msc > 0 ? tick.time_msc : NowMsc()),
                       StringSubstr(EnumToString(trans.type), 18),
                       trans.order, trans.deal, trans.position, trans.symbol,
                       EnumToString(trans.order_type), EnumToString(trans.order_state),
                       EnumToString(trans.deal_type), entry,
                       trans.volume, Px(trans.price), Px(trans.price_sl), Px(trans.price_tp),
                       profit, Px(tick.bid), Px(tick.ask), magic, comment));
  }
