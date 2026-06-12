unit uGUI;

interface

uses
  Windows, Classes, Graphics, Controls, Forms;

type
  TEventType = (etMouseDown, etMouseUp, etMouseMove, etMouseClick, etDraw, etUpdate);

  TMouseEvent = record
    Button: TMouseButton;
    Shift : TShiftState;
  end;

  TControlEvent = record
    case ID: TEventType of
      etDraw, etUpdate: ();
      etMouseClick, etMouseDown, etMouseUp, etMouseMove: (Mouse: TMouseEvent);
  end;

  TRectP = record
  public
    Left, Top, Right, Bottom: LongInt;
    constructor Create(const aLeft, aTop, aWidth, aHeight: LongInt);
    function Width: LongInt;
    function Height: LongInt;
    function Rect: TRect;
  end;

  TProc = procedure(me: TMouseEvent) of object;
  TGUI = class;

  TWidget = class
  protected
    FActive  : Boolean;
    FRect    : TRectP;
    FGUI     : TGUI;
    FOnClick : TProc;
  public
    IsMouse: Boolean;
    Visible: Boolean;
    constructor Create(const aGUI: TGUI; const Rect: TRectP; ClickProc: TProc=nil); virtual;
    destructor Destroy; override;
    procedure Draw; virtual;
    procedure Move(const aLeft, aTop, aWidth, aHeight: LongInt); virtual;
    procedure OnEvent(X, Y: LongInt; Event: TControlEvent); virtual;
    property Active:  Boolean read FActive;
    property GUI: TGUI read FGUI;
    property Left: LongInt read FRect.Left;
    property Top: LongInt read FRect.Top;
    property Rect: TRectP read FRect;
  end;

  TLogView = class(TWidget)
  private
    FLines: TStringList;
    FFontHeight: LongInt;
    FSelectedLine: LongInt;  
  public
    Focused: Boolean; 
    ScrollPos: LongInt;      
    constructor Create(const aGUI: TGUI; const Rect: TRectP; ClickProc: TProc=nil); override;
    destructor Destroy; override;
    procedure AddLine(const Msg: string; const AColor: TColor);
    procedure Clear;
    procedure Draw; override;
    procedure OnEvent(X, Y: LongInt; Event: TControlEvent); override;
    function GetLineText(Index: LongInt): string;
    procedure SelectFirstError; 
    property FontHeight: LongInt read FFontHeight;
    property SelectedLine: LongInt read FSelectedLine;
    property Lines: TStringList read FLines;
  end;

  TGUI = class
  private
    List: TList;
    function Get(Index: LongInt): TWidget;
  public
    Canvas: TCanvas;
    constructor Create(aCanvas: TCanvas);
    destructor Destroy; override;
    procedure SetEvent(X, Y: Integer; Event: TControlEvent);
  end;

implementation


function RectIntersect(const mX, mY, aL, aT, aW, aH: Integer): Boolean;
begin
  Result := (aL <= mX) and (aL + aW >= mX) and
            (aT <= mY) and (aT + aH >= mY);
end;

{ TRectP }
constructor TRectP.Create(const aLeft, aTop, aWidth, aHeight: LongInt);
begin
  Left := aLeft; Top := aTop; Right := aLeft + aWidth; Bottom := aTop + aHeight;
end;

function TRectP.Width: LongInt;
begin
  Result := Right - Left;
end;

function TRectP.Height: LongInt;
begin
  Result := Bottom - Top;
end;

function TRectP.Rect: TRect;
begin
  Result := Classes.Rect(Left, Top, Right, Bottom);
end;

{ TWidget }
constructor TWidget.Create(const aGUI: TGUI; const Rect: TRectP; ClickProc: TProc);
begin
  Visible := True;
  FGUI := aGUI;
  FActive := False;
  FOnClick := ClickProc;
  FRect := Rect;
  FGUI.List.Add(Self);
end;

destructor TWidget.Destroy;
begin
  inherited;
end;

procedure TWidget.Draw;
begin
end;

procedure TWidget.Move(const aLeft, aTop, aWidth, aHeight: LongInt);
begin 
  FRect.Left := aLeft; 
  FRect.Top := aTop; 
  FRect.Right := aLeft + aWidth; 
  FRect.Bottom := aTop + aHeight; 
end;

procedure TWidget.OnEvent(X, Y: LongInt; Event: TControlEvent);
begin
  case Event.ID of
    etMouseMove:
      IsMouse := RectIntersect(X, Y, FRect.Left, FRect.Top, FRect.Width, FRect.Height);

    etMouseDown:
      if RectIntersect(X, Y, FRect.Left, FRect.Top, FRect.Width, FRect.Height) then
        FActive := True;

    etMouseUp: begin
      if FActive and Assigned(FOnClick) then
        FOnClick(Event.Mouse);

      FActive := False;
    end;

    etDraw: Draw;
  end;
end;


{ TGUI }
function TGUI.Get(Index: LongInt): TWidget;
begin
  Result := TWidget(List.Items[Index]);
end;

constructor TGUI.Create(aCanvas: TCanvas);
begin
  Canvas := aCanvas;
  List := TList.Create;
end;

destructor TGUI.Destroy;
var
  i: LongInt;
begin
  for i := 0 to List.Count - 1 do
    Get(i).Free;
  List.Free;
  inherited;
end;

procedure TGUI.SetEvent(X, Y: Integer; Event: TControlEvent);
var i: LongInt;
begin
  for i := 0 to List.Count - 1 do
    if Get(i).Visible then
      Get(i).OnEvent(X, Y, Event);
end;

{ TLogTextView }
constructor TLogView.Create(const aGUI: TGUI; const Rect: TRectP; ClickProc: TProc);
begin
  inherited Create(aGUI, Rect, ClickProc);
  FLines := TStringList.Create;
  FFontHeight := 16;
  FSelectedLine := -1;
  ScrollPos := 0;
  Focused := False;
end;

destructor TLogView.Destroy;
begin
  FLines.Free;
  inherited;
end;

procedure TLogView.Clear;
begin
  FLines.Clear;
  FSelectedLine := -1;
  ScrollPos := 0;
end;

procedure TLogView.AddLine(const Msg: string; const AColor: TColor);
begin
  FLines.AddObject(Msg, TObject(AColor));
end;

function TLogView.GetLineText(Index: LongInt): string;
begin
  if (Index >= 0) and (Index < FLines.Count) then
    Result := FLines[Index]
  else Result := '';
end;

procedure TLogView.SelectFirstError;
var 
  i: Integer;
  CurrentColor: TColor;
begin
  // Сканируем строки нашего единого списка FLines
  for i := 0 to FLines.Count - 1 do
  begin
    // Вытаскиваем цвет из Objects, приводя указатель обратно к TColor
    CurrentColor := TColor(FLines.Objects[i]);
    
    // Ищем красный (Error) или оранжево-красный (Fatal) маркеры
    if (CurrentColor = $0000FF) or (CurrentColor = $006AFF) then
    begin
      FSelectedLine := i; // Ставим нашу светло-голубую полосу выделения
      
      // Если строка с ошибкой находится выше текущего экрана — подтягиваем скролл к ней
      if i < ScrollPos then 
        ScrollPos := i;
        
      Exit; // Первую ошибку нашли и подсветили, уходим!
    end;
  end;
end;

procedure TLogView.Draw;
var
  i, MaxVisible, CurrY: LongInt;
  LineIdx: LongInt;
  R: TRect;
begin
  // ЗАТИРАЕМ КЛИЕНТСКУЮ ОБЛАСТЬ
  FGUI.Canvas.Brush.Color := clWhite;
  FGUI.Canvas.FillRect(FRect.Rect);

  // Настраиваем шрифт
  FGUI.Canvas.Font.Name := 'Consolas';
  FGUI.Canvas.Font.Size := 10;
  FGUI.Canvas.Font.Style := [];
  FFontHeight := FGUI.Canvas.TextHeight('Wj') + 1;

  CurrY := FRect.Top;
  MaxVisible := FRect.Height div FFontHeight;

  for i := 0 to MaxVisible do
  begin
    LineIdx := ScrollPos + i;
    if LineIdx >= FLines.Count then Break;

    // Светло-голубая полоса выделения
    if LineIdx = FSelectedLine then
    begin
      FGUI.Canvas.Brush.Color := $FFF0DC; // Пастельный бледно-голубой
      R := Classes.Rect(FRect.Left, CurrY, FRect.Right - 2, CurrY + FFontHeight);
      FGUI.Canvas.FillRect(R);
      
      // АПЕЛЬСИНOВЫЙ ОРГАЗМ: Зажигаем рамку по фокусу окна!
      if Focused then
      begin
        FGUI.Canvas.Pen.Color := $0055FF; // Сочный оранжевый (BGR)
        FGUI.Canvas.Pen.Width := 1;
        FGUI.Canvas.Pen.Style := psSolid;
        FGUI.Canvas.Brush.Style := bsClear;

        // Рисуем рамку через Rectangle, который подчиняется Pen.Color!
        FGUI.Canvas.Rectangle(R.Left + 1, R.Top + 1, R.Right - 1, R.Bottom + 1);
      end;
    end;

    // Выводим крашеную строку лога с отступом слева
    FGUI.Canvas.Font.Color := TColor(FLines.Objects[LineIdx]);
    FGUI.Canvas.Brush.Style := bsClear;
    FGUI.Canvas.TextOut(FRect.Left + 8, CurrY + 1, FLines[LineIdx]);
    
    Inc(CurrY, FFontHeight);
  end;
end;

procedure TLogView.OnEvent(X, Y: LongInt; Event: TControlEvent);
var
  ClickedLine: LongInt;
begin
  inherited OnEvent(X, Y, Event);

  case Event.ID of
    etMouseDown:
    begin
      if FActive then
      begin
        ClickedLine := ScrollPos + ((Y - FRect.Top) div FFontHeight);
        if (ClickedLine >= 0) and (ClickedLine < FLines.Count) then
        begin
          FSelectedLine := ClickedLine; // Полосочка выделения
        end;
      end;
    end;

    // ОБРАБОТКА ПОЛНОЦЕННОГО КЛИКА ДЛЯ CALLBACK ВЫЗOВА
    etMouseClick:
    begin
      // Если мышь отпустили там же, где нажали (активность подтверждена предком)
      if RectIntersect(X, Y, FRect.Left, FRect.Top, FRect.Width, FRect.Height) then
      begin
        if Assigned(FOnClick) then
          FOnClick(Event.Mouse); // Стреляем в LogViewClick в uLogExpert!
      end;
    end;
  end;
end;

end.
