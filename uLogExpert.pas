unit uLogExpert;

interface

uses 
  Windows, Messages, SysUtils, StrUtils, Classes, Forms, Controls, ExtCtrls,
  Registry, Menus, StdCtrls, CommCtrl, Graphics, ActnList, ToolsAPI,
  uGUI; // Кастомный Canvas-движок

procedure Register;

const
  WM_PIPE_OUTPUT = WM_USER + 777;
  REG_VAL_ENABLED = 'Enabled';

type
  // Чистый интерфейс эксперта для гарантированного автостарта плагина в Delphi 2007
  TFixIDEWizard = class(TInterfacedObject, IOTAWizard, IOTANotifier)
  public
    // IOTANotifier
    procedure AfterSave;
    procedure BeforeSave;
    procedure Destroyed;
    procedure Modified;
    // IOTAWizard
    function GetIDString: String;
    function GetName: String;
    function GetState: TWizardState;
    procedure Execute;
  end;

  // Поток скрытой консоли для работы с DCC32
  TPipeConsole = class(TThread)
  private
    FCS: TRtlCriticalSection;
    FBuffer: array [0..4095] of Char;
    FDummy: Cardinal;
    FhProcess        : THandle;
    FhPipeInputRead  : THandle;
    FhPipeInputWrite : THandle;
    FhPipeOutputRead : THandle;
    FhPipeOutputWrite: THandle;
  protected
    procedure Execute; override;
  public
    Tag: LongInt;
    constructor CreateConsole;
    destructor Destroy; override;
    procedure SignCmd(Line: string);
  end;

  // Форма лога, вживляемая в Delphi
  TLogForm = class(TForm)
  private
    FBuffer: TBitmap;
    FReturnBuffer: String;
    procedure ProcessIncomingLine(const Line: String);
    procedure UpdateWinAPIScrollBar; // Настройка нативного скроллбара
    procedure DrawControls;
    procedure LogViewClick(me: TMouseEvent);
  public
    FLogGUI: TGUI;               // Менеджер GUI
    FLogView: TLogView;          // Canvas-контрол строк
    procedure WMPipeOutput(var Msg: TMessage); message WM_PIPE_OUTPUT;
    constructor CreateNew(AOwner: TComponent; Dummy: Integer = 0); override;
    destructor Destroy; override;
  protected
    procedure WndProc(var Message: TMessage); override;
  end;

  TTimerWrapper = class
  public
    procedure OnScanTimerTick(Sender: TObject);
  end;

  TPluginWrapper = class
    procedure OnMenuToggleClick(Sender: TObject);
  end;

  procedure RunOurDccCompiler;
  procedure CreatePluginMenu;
  procedure RemovePluginMenu;
  procedure LoadPluginSettings;
  procedure SavePluginSettings;
  procedure SetPluginActive(const Value: Boolean);
  procedure JumpToSourceCode(const LogLine: String; const AColor: TColor);

var
  MyLogForm: TLogForm = nil;
  FScanTimer: TTimer = nil;
  FPluginEnabled: Boolean = True;
  FPluginWrapper: TPluginWrapper = nil;
  FTimerWrapper: TTimerWrapper = nil;
  FCompilerPipe: TPipeConsole = nil;
  FKeyHook: HHOOK = 0;
  FIsOurCompilation: Boolean = False;
  FActionFix: TAction = nil;
  DelphiBinPath: String = '';
  DelphiHintWindowWnd: HWND = 0;
  DelphiOriginalParentWnd: HWND = 0;

  
implementation

{ TFixIDEWizard }
procedure TFixIDEWizard.AfterSave; begin end;
procedure TFixIDEWizard.BeforeSave; begin end;
procedure TFixIDEWizard.Destroyed; begin end;
procedure TFixIDEWizard.Modified; begin end;

function TFixIDEWizard.GetIDString: String;
begin
  Result := 'IDE.CompileFix.Wizard';
end;

function TFixIDEWizard.GetName: String;
begin
  Result := 'IDE Compile Fix Win10';
end;

function TFixIDEWizard.GetState: TWizardState;
begin
  Result := [wsEnabled];
end;

procedure TFixIDEWizard.Execute; begin end;

{ Вспомогательные функции поиска путей и окон }

function GetDelphi2007BinPath: String;
var
  Reg: TRegistry;
  ShortBuf: array [0..MAX_PATH] of Char;
begin
  Result := ''; Reg := TRegistry.Create(KEY_READ);
  try
    Reg.RootKey := HKEY_CURRENT_USER;
    if Reg.OpenKey('Software\Borland\BDS\5.0', False) then
    begin
      Result := Reg.ReadString('RootDir');
      Reg.CloseKey;
    end;

    if Result = '' then
    begin
      Reg.RootKey := HKEY_LOCAL_MACHINE;
      if Reg.OpenKey('Software\CodeGear\BDS\5.0', False) or Reg.OpenKey('Software\Wow6432Node\CodeGear\BDS\5.0', False) then
      begin
        Result := Reg.ReadString('RootDir');
        Reg.CloseKey;
      end;
    end;
  finally
    Reg.Free;
  end;

  if Result <> '' then
  begin
    // Переводим абсолютные пути и папки в DOS-формат (защита от пробелов в Win10)
    GetShortPathName(PChar(IncludeTrailingPathDelimiter(Result) + 'bin\dcc32.exe'), ShortBuf, MAX_PATH);
    Result := String(ShortBuf);
  end
  else Result := 'dcc32.exe';
end;

function GetProjectPathDynamic: String;
var
  ModServices: IOTAModuleServices;
  ProjGroup: IOTAProjectGroup;
  ActProj: IOTAProject;
  I: Integer;
begin
  Result := '';
  if BorlandIDEServices = nil then Exit;
  if Supports(BorlandIDEServices, IOTAModuleServices, ModServices) then
  begin
    for I := 0 to ModServices.ModuleCount - 1 do
      if Supports(ModServices.Modules[I], IOTAProjectGroup, ProjGroup) then
      begin
        ActProj := ProjGroup.ActiveProject;
        if ActProj <> nil then
        begin
          Result := ActProj.FileName;
          Exit;
        end;
      end;
    for I := 0 to ModServices.ModuleCount - 1 do
      if Supports(ModServices.Modules[I], IOTAProject, ActProj) then
      begin
        Result := ActProj.FileName;
        Exit;
      end;
  end;
end;

function FindChildWindowByClass(ParentHWnd: HWND; const TargetClassName: String): HWND;
var
  ChildHWnd: HWND;
  FoundClassName: String;
begin
  Result := 0; ChildHWnd := FindWindowEx(ParentHWnd, 0, nil, nil);
  while ChildHWnd <> 0 do
  begin
    SetLength(FoundClassName, 255);
    GetClassName(ChildHWnd, PChar(FoundClassName), 255);
    FoundClassName := PChar(FoundClassName);
    if SameText(FoundClassName, TargetClassName) then
    begin
      Result := ChildHWnd;
      Exit;
    end;

    Result := FindChildWindowByClass(ChildHWnd, TargetClassName);

    if Result <> 0 then Exit;
    ChildHWnd := FindWindowEx(ParentHWnd, ChildHWnd, nil, nil);
  end;
end;

{ TPipeConsole — ПОТOК СКРЫТOЙ КОНСOЛИ ДЛЯ РАБOТЫ С DCC32 }

constructor TPipeConsole.CreateConsole;
var
  SA: TSecurityAttributes;
  SI: TStartupInfo;
  PI: TProcessInformation;
begin
  inherited Create(True);
  InitializeCriticalSection(FCS);
  SA.nLength := SizeOf(TSecurityAttributes);
  SA.lpSecurityDescriptor := nil;
  SA.bInheritHandle := True;
  CreatePipe(FhPipeInputRead, FhPipeInputWrite, @SA, 0);
  CreatePipe(FhPipeOutputRead, FhPipeOutputWrite, @SA, 0);
  ZeroMemory(@SI, SizeOf(TStartupInfo));
  ZeroMemory(@PI, SizeOf(TProcessInformation));
  SI.cb := SizeOf(TStartupInfo);
  SI.dwFlags := STARTF_USESHOWWINDOW or STARTF_USESTDHANDLES;
  SI.wShowWindow := SW_HIDE;
  SI.hStdInput := FhPipeInputRead;
  SI.hStdOutput := FhPipeOutputWrite;
  SI.hStdError := FhPipeOutputWrite;
  if CreateProcess(nil, PChar('cmd.exe'), nil, nil, True, CREATE_NEW_CONSOLE, nil, nil, SI, PI) then
  begin
    FhProcess := PI.hProcess;
    CloseHandle(PI.hThread);
  end;
  Tag := 1;
  FreeOnTerminate := False;
  Resume;
end;

destructor TPipeConsole.Destroy;
begin
  if FhProcess <> 0 then
  begin
    TerminateProcess(FhProcess, 255);
    WaitForSingleObject(FhProcess, INFINITE);
    CloseHandle(FhProcess);
  end;

  CloseHandle(FhPipeInputWrite);
  CloseHandle(FhPipeInputRead);
  CloseHandle(FhPipeOutputWrite);
  CloseHandle(FhPipeOutputRead);
  DeleteCriticalSection(FCS);

  inherited Destroy;
end;

procedure TPipeConsole.Execute;
var
  PStr: PChar;
begin
  while not Terminated do
  begin
    if ReadFile(FhPipeOutputRead, FBuffer, Length(FBuffer) - 1, FDummy, nil) then
    begin
      if FDummy > 0 then
      begin
        EnterCriticalSection(FCS);
        OemToAnsiBuff(FBuffer, FBuffer, FDummy);
        FBuffer[FDummy] := #0;
        PStr := StrNew(FBuffer);
        if MyLogForm <> nil then
          PostMessage(MyLogForm.Handle, WM_PIPE_OUTPUT, 0, LPARAM(PStr));
        LeaveCriticalSection(FCS);
      end;
    end
    else Sleep(10);
  end;
end;

procedure TPipeConsole.SignCmd(Line: String);
var
  CmdLine: AnsiString;
  BytesWritten: Cardinal;
begin
  CmdLine := AnsiString(Line + #13#10);
  if (FhPipeInputWrite <> 0) and (Length(CmdLine) > 0) then
  begin
    EnterCriticalSection(FCS);
    try
      WriteFile(FhPipeInputWrite, Pointer(CmdLine)^, Length(CmdLine), BytesWritten, nil);
      FlushFileBuffers(FhPipeInputWrite);
    finally
      LeaveCriticalSection(FCS);
    end;
  end;
end;

{ --- ЯДРО КОМПИЛЯЦИИ И КЛАВИАТУРНЫЙ ХУК --- }

procedure RunOurDccCompiler;
var
  I: Integer;
  DynamicProjectPath, CleanProjectPath, DccCmd, ShortPath, ShortProjPath: String;
  ShortBuf: array [0..MAX_PATH] of Char;
  ModuleServices: IOTAModuleServices;
begin
  FIsOurCompilation := True;
  
  if (MyLogForm <> nil) and (MyLogForm.FLogView <> nil) then
    MyLogForm.FLogView.Clear;

  if Supports(BorlandIDEServices, IOTAModuleServices, ModuleServices) then
    ModuleServices.SaveAll;

  DynamicProjectPath := GetProjectPathDynamic;
  if (DynamicProjectPath <> '') and (FCompilerPipe <> nil) then
  begin
    if SameText(ExtractFileExt(DynamicProjectPath), '.dproj') then
    begin
      CleanProjectPath := ChangeFileExt(DynamicProjectPath, '.dpr');
      if not FileExists(CleanProjectPath) then
        CleanProjectPath := ChangeFileExt(DynamicProjectPath, '.dpk');
    end
    else CleanProjectPath := DynamicProjectPath;

    // Переводим абсолютные пути и папки в DOS-формат (защита от пробелов в Win10)
    GetShortPathName(PChar(CleanProjectPath), ShortBuf, MAX_PATH);
    ShortPath := String(ShortBuf);
    
    GetShortPathName(PChar(ExtractFilePath(CleanProjectPath)), ShortBuf, MAX_PATH);
    ShortProjPath := String(ShortBuf);

    if (MyLogForm <> nil) and (MyLogForm.FLogView <> nil) then
    begin
      MyLogForm.FLogView.AddLine('--- СБОРКА АКТИВНОГО ПРОЕКТА: ' + ExtractFileName(CleanProjectPath) + ' ---', $804000);
      MyLogForm.UpdateWinAPIScrollBar;
      InvalidateRect(MyLogForm.Handle, nil, True);
      Windows.UpdateWindow(MyLogForm.Handle);
    end;

    // Собираем строку компиляции для dcc32
    //DccCmd := Format('CD /d %s && C:\PROGRA~2\D2007\bin\dcc32.exe -B -Q -$D+ -$L+ ' + ShortPath, [ShortProjPath]);
    DccCmd := Format('CD /d %s && %s -B -Q -$D+ -$L+ ' + ShortPath, [ShortProjPath, DelphiBinPath]);
    FCompilerPipe.SignCmd(DccCmd);
    
    for I := 0 to Screen.FormCount - 1 do
      if SameText(Screen.Forms[I].ClassName, 'TMessageViewForm') then
        Screen.Forms[I].Visible := True;
  end;
end;

function KeyboardHookProc(Code: Integer; wParam: WPARAM; lParam: LPARAM): LRESULT; stdcall;
begin
  if not FPluginEnabled then
  begin
    Result := CallNextHookEx(FKeyHook, Code, wParam, lParam);
    Exit;
  end;

  if (Code = HC_ACTION) and (wParam = VK_F9) and ((GetKeyState(VK_CONTROL) and $8000) <> 0) then
  begin
    if (lParam and $80000000) = 0 then 
    begin
      RunOurDccCompiler; // Нажали Ctrl+F9 — напрямую запустили компилятор!
    end;
    Result := 1; 
    Exit; // Глотаем нажатие для Delphi IDE
  end;
  Result := CallNextHookEx(FKeyHook, Code, wParam, lParam);
end;

{ --- ГЛАВНАЯ ПРОЦЕДУРА JUMP TO SOURCE CODE ЧЕРЕЗ TOOLS API --- }

procedure JumpToSourceCode(const LogLine: String; const AColor: TColor);
var
  FileName, CleanPath, ProjDir, ErrText, TargetToken: String;
  LineNum, ColNum, P1, P2, PTokenStart, PTokenEnd, I: Integer;
  ModServices: IOTAModuleServices;
  ActServices: IOTAActionServices;
  EdServices: IOTAEditorServices;
  Module: IOTAModule;
  EdBuffer: IOTAEditBuffer;
  EdPos: IOTAEditPosition;
  EdView: IOTAEditView;
  EditWnd: HWND;

  FileLines: TStringList;
  TargetLineText: String;

  // Переменные для WinAPI рендеринга адаптивного маркера
  R: TRect;
  DC: HDC;
  MarkerBrush: HBRUSH;
  CaretPt: TPoint;
  ColStr: AnsiString;
  TextSize: TSize;
  MarkerWidth: Integer;
begin
  P1 := Pos('(', LogLine);
  P2 := Pos(')', LogLine);
         
  if (P1 > 0) and (P2 > P1) then
  begin
    FileName := Copy(LogLine, 1, P1 - 1);
    LineNum := StrToIntDef(Trim(Copy(LogLine, P1 + 1, P2 - P1 - 1)), 1);

    if (FileName <> '') and (LineNum > 0) then
    begin
      if Supports(BorlandIDEServices, IOTAModuleServices, ModServices) and
         Supports(BorlandIDEServices, IOTAActionServices, ActServices) and
         Supports(BorlandIDEServices, IOTAEditorServices, EdServices) then
      begin
        ProjDir := ExtractFilePath(GetProjectPathDynamic);
        if (Length(FileName) > 3) and (FileName = ':') then 
          CleanPath := FileName
        else 
          CleanPath := ProjDir + ExtractFileName(FileName);

        if (CleanPath <> '') and (ExtractFileExt(CleanPath) = '') then 
          CleanPath := CleanPath + '.pas';

        Module := ModServices.FindModule(CleanPath);
        if Module <> nil then
        begin
          Module.Show;
          Application.ProcessMessages;
        end
        else
        begin
          if FileExists(CleanPath) then
          begin
            ActServices.OpenFile(CleanPath);
            Application.ProcessMessages;
            Module := ModServices.FindModule(CleanPath);
          end;
        end;

        if (Module <> nil) and (EdServices.TopBuffer <> nil) and Supports(EdServices.TopBuffer, IOTAEditBuffer, EdBuffer) then
        begin
          EdPos := EdBuffer.GetEditPosition;
          ColNum := 1; // Дефолт

          if EdPos <> nil then
          begin
            ErrText := Copy(LogLine, P2 + 1, Length(LogLine) - P2);
            
            PTokenStart := Pos('''', ErrText);
            if PTokenStart = 0 then PTokenStart := Pos('‘', ErrText);
            if PTokenStart = 0 then PTokenStart := Pos('’', ErrText);

            if PTokenStart > 0 then
            begin
              PTokenEnd := StrUtils.PosEx('''', ErrText, PTokenStart + 1);
              if PTokenEnd = 0 then PTokenEnd := StrUtils.PosEx('’', ErrText, PTokenStart + 1);

              if PTokenEnd > PTokenStart then
              begin
                TargetToken := Copy(ErrText, PTokenStart + 1, PTokenEnd - PTokenStart - 1);
                
                if FileExists(CleanPath) then
                begin
                  FileLines := TStringList.Create; // Приходится идти на эту херню, т.к API CodeGear не умеет работать с рускими символами!
                  try                              // Вдруг мы наляпаем непредсказуемых ошибок, для корректной обработки...
                    FileLines.LoadFromFile(CleanPath);
                    I := LineNum - 1;
                    if (I >= 0) and (I < FileLines.Count) then
                    begin
                      TargetLineText := FileLines[I];
                      ColNum := Pos(UpperCase(TargetToken), UpperCase(TargetLineText));
                      if ColNum = 0 then ColNum := 1;
                    end;
                  finally
                    FileLines.Free;
                  end;
                end;
              end;
            end;

            // НАДЕЖНО ДВИГАЕМ КАРЕТКУ TOOLS API НА СТРОКУ И ВЫЧИСЛЕННЫЙ СТОЛБЕЦ
            EdPos.Move(LineNum, ColNum);

            if EdServices.TopBuffer.EditViewCount > 0 then
            begin
              EdView := EdServices.TopBuffer.EditViews[0]; 
              if EdView <> nil then
              begin
                EdView.MoveCursorToView; // Центрируем экран редактора на ошибке
                
                if Application.MainForm <> nil then
                  EditWnd := FindChildWindowByClass(Application.MainForm.Handle, 'TEditControl');
                  
                if EditWnd <> 0 then 
                begin
                  Windows.SetFocus(EditWnd); // Отдаем фокус в код
                  
                  // Пинки очереди для фикса зоны видимости по канонам CnPack
    {<-}          Windows.Sleep(50); // Задержка нужна для статусного маркера, чтобы среда успела прокрутить окнами, скроллами
                  Application.ProcessMessages;
                  Windows.RedrawWindow(EditWnd, nil, 0, RDW_INVALIDATE or RDW_UPDATENOW);          

                  if Windows.GetCaretPos(CaretPt) then 
                  begin
                    DC := GetDC(EditWnd); 
                    if DC <> 0 then
                    begin
                      try
                        ColStr := AnsiString(IntToStr(ColNum));
                        
                        // Загружаем компактный системный шрифт в DC для точного замера текста
                        SelectObject(DC, GetStockObject(ANSI_FIXED_FONT));
                        
                        // АДАПТИВНЫЙ ФИКС ДЛЯ СТОЛБЦОВ > 99:
                        // Замеряем ширину цифр в пикселях на лету!
                        GetTextExtentPoint32A(DC, PAnsiChar(ColStr), Length(ColStr), TextSize);
                        
                        // Вычисляем ширину маркера: ширина текста + 6 пикселей отступов (минимум 14 пикселей)
                        MarkerWidth := TextSize.cx + 6;
                        if MarkerWidth < 14 then MarkerWidth := 14;

                        // Формируем прямоугольник кубика, который сам раздвигается вправо!
                        R.Left := 1;                   
                        R.Top := CaretPt.Y + 1;        // Сдвиг на 1px
                        R.Right := R.Left + MarkerWidth; // ДИНАМИЧЕСКАЯ ШИРИНА КУБИКА!
                        R.Bottom := CaretPt.Y + 16;    // Высота кубика

                        // Заливаем маркер готовым цветом ошибки, который прилетел в параметре AColor!
                        MarkerBrush := CreateSolidBrush(AColor); 
    {<-номер}           FillRect(DC, R, MarkerBrush); // Заливаем фон
                        DeleteObject(MarkerBrush);
                        
                        // Настраиваем контекст рисования текста внутри кубика
                        SetTextColor(DC, RGB(255, 255, 255));
                        SetBkMode(DC, TRANSPARENT);
                        
                        // Печатаем номер столбца строго по центру нашего адаптивного кубика
                        DrawTextA(DC, PAnsiChar(ColStr), Length(ColStr), R, DT_CENTER or DT_VCENTER or DT_SINGLELINE);
                      finally
                        ReleaseDC(EditWnd, DC);
                      end;
                    end;
                  end;
                end;
              end;
            end;
          end;
        end;
      end;
    end;
  end;
end;

{ TLogForm — ИНИЦИАЛИЗАЦИЯ И ПАРСИНГ СТРOК }

// Функция перевода мышиных мессаджей в структуру твоего GUI
function MakeMouseEvent(Msg: Cardinal; wParam: WPARAM): TControlEvent;
begin
  ZeroMemory(@Result, SizeOf(TControlEvent));
  case Msg of
    WM_LBUTTONDOWN, WM_RBUTTONDOWN: Result.ID := etMouseDown;
    WM_LBUTTONUP, WM_RBUTTONUP:     Result.ID := etMouseUp;
    WM_MOUSEMOVE:                   Result.ID := etMouseMove;
  end;
  if (Msg = WM_LBUTTONDOWN) or (Msg = WM_LBUTTONUP) then Result.Mouse.Button := mbLeft;
  if (Msg = WM_RBUTTONDOWN) or (Msg = WM_RBUTTONUP) then Result.Mouse.Button := mbRight;
  Result.Mouse.Shift := [];
  if (wParam and MK_CONTROL) <> 0 then Include(Result.Mouse.Shift, ssCtrl);
  if (wParam and MK_SHIFT) <> 0 then   Include(Result.Mouse.Shift, ssShift);
end;

constructor TLogForm.CreateNew(AOwner: TComponent; Dummy: Integer = 0);
var
  Style: LongInt;
begin
  inherited CreateNew(AOwner, Dummy);
  FormStyle := fsNormal;
  BorderStyle := bsNone;
  
  // Жестко приклеиваем WS_VSCROLL для нативного ползунка прокрутки Windows
  Style := GetWindowLong(Handle, GWL_STYLE);
  Style := Style and (not (WS_CAPTION or WS_SYSMENU or WS_THICKFRAME or WS_MINIMIZEBOX or WS_MAXIMIZEBOX));
  Style := Style or WS_VSCROLL;
  SetWindowLong(Handle, GWL_STYLE, Style);
  
  FReturnBuffer := '';
  DoubleBuffered := False;

  // Инициализируем графический буфер в памяти
  FBuffer := TBitmap.Create;
  FBuffer.Width := ClientWidth;
  FBuffer.Height := ClientHeight;

  // Инициализируем твой GUI менеджер на Canvas формы и сажаем туда текстовый контрол
  FLogGUI := TGUI.Create(FBuffer.Canvas);
  FLogView := TLogView.Create(FLogGUI, TRectP.Create(0, 0, ClientWidth, ClientHeight), LogViewClick);
end;

destructor TLogForm.Destroy;
begin
  if FLogGUI <> nil then FreeAndNil(FLogGUI);
  if FBuffer <> nil then FreeAndNil(FBuffer);
  inherited;
end;

procedure TLogForm.DrawControls;
var
  CE: TControlEvent;
begin
  if (FBuffer = nil) or (FLogGUI = nil) or (FLogView = nil) then Exit;

  // Очистка буфера под цвет окна лога
  FBuffer.Canvas.Brush.Color := clWhite;
  FBuffer.Canvas.FillRect(Rect(0, 0, FBuffer.Width, FBuffer.Height));

  // Рендерим твой GUI прямо в память буфера
  ZeroMemory(@CE, SizeOf(TControlEvent));
  CE.ID := etDraw;
  FLogGUI.SetEvent(0, 0, CE);

  // Мгновенно выплескиваем готовый буфер на экран через BitBlt
  BitBlt(Self.Canvas.Handle, 0, 0, FBuffer.Width, FBuffer.Height, FBuffer.Canvas.Handle, 0, 0, SRCCOPY);
end;

procedure TLogForm.UpdateWinAPIScrollBar;
var 
  SI: TScrollInfo;
begin
  if FLogView = nil then Exit;
  ZeroMemory(@SI, SizeOf(TScrollInfo));
  SI.cbSize := SizeOf(TScrollInfo);
  SI.fMask := SIF_RANGE or SIF_PAGE or SIF_POS;
  SI.nMin := 0; 
  SI.nMax := FLogView.Lines.Count - 1; 
  SI.nPage := ClientHeight div FLogView.FontHeight; // Сколько строк влезает
  SI.nPos := FLogView.ScrollPos;
  SetScrollInfo(Handle, SB_VERT, SI, True); // Windows сама выведет ползунок прокрутки!
end;

procedure TLogForm.LogViewClick(me: TMouseEvent);
var
  CurrentLineColor: TColor;
begin
  // Если при клике по Canvas-строке лога был зажат CTRL
  if (GetKeyState(VK_CONTROL) and $8000) <> 0 then
  begin
    if (FLogView <> nil) and (FLogView.SelectedLine >= 0) then
    begin
      SetCursor(LoadCursor(0, IDC_IBEAM));
      CurrentLineColor := TColor(FLogView.Lines.Objects[FLogView.SelectedLine]);
      JumpToSourceCode(Trim(FLogView.Lines[FLogView.SelectedLine]), CurrentLineColor);
    end;
  end;
end;

procedure TLogForm.WMPipeOutput(var Msg: TMessage);
var
  PStr: PChar;
  LinePos: Integer;
  CurrLine: String;
begin
  PStr := PChar(Msg.LParam);
  if PStr <> nil then
  begin
    Self.FReturnBuffer := Self.FReturnBuffer + String(PStr);
    while True do
    begin
      LinePos := Pos(#13#10, string(Self.FReturnBuffer));
      if LinePos = 0 then LinePos := Pos(#10, string(Self.FReturnBuffer));
      if LinePos = 0 then LinePos := Pos(#13, string(Self.FReturnBuffer));
      if LinePos > 0 then
      begin
        CurrLine := Copy(Self.FReturnBuffer, 1, LinePos - 1);
        CurrLine := StringReplace(CurrLine, #13, '', [rfReplaceAll]);
        CurrLine := StringReplace(CurrLine, #10, '', [rfReplaceAll]);
        ProcessIncomingLine(CurrLine); Delete(Self.FReturnBuffer, 1, LinePos);
      end
      else Break;
    end;
  end;
end;

procedure TLogForm.ProcessIncomingLine(const Line: string);
var
  Str: String;
  IsCompilationFinished: Boolean;
begin
  Str := Trim(Line); if Str = '' then Exit;
  if (Pos('Microsoft', Str) > 0) or (Pos('dcc32.exe', Str) > 0) then Exit;

  IsCompilationFinished := False;

  if (Pos('Error:', Str) > 0) then
  begin
    FLogView.AddLine(Str, $0000FF);
    Windows.SetFocus(Handle);
  end
  else if (Pos('Fatal:', Str) > 0) then
  begin
    FLogView.AddLine(Str, $006AFF);
    Windows.SetFocus(Handle);
    IsCompilationFinished := True;
  end
  else if (Pos('Warning:', Str) > 0) then FLogView.AddLine(Str, $0070A0)
  else if (Pos('Hint:', Str) > 0) then FLogView.AddLine(Str, $FF8000)
  else if (Pos('Success', Str) > 0) or (Pos('lines', Str) > 0) then
  begin
    FLogView.AddLine(Str, $008000); Windows.SetFocus(Handle); IsCompilationFinished := True;
  end
  else FLogView.AddLine(Str, $404040);

  UpdateWinAPIScrollBar;
  DrawControls(); // Мгновенно отрисовываем буфер на каждую новую строку!

  if IsCompilationFinished then
  begin
    FIsOurCompilation := False;
    FLogView.SelectFirstError;
    UpdateWinAPIScrollBar;
    DrawControls(); // Финальный рендер с полосой выделения ошибки
    
    if FPluginEnabled and Assigned(FScanTimer) then
      FScanTimer.Enabled := True;
  end;
end;

{ TLogForm — ОКOННЫЙ ДИСПЕТЧЕР WNDPROC }

procedure TLogForm.WndProc(var Message: TMessage);
var 
  CE: TControlEvent; 
  SI: TScrollInfo; 
  WheelDelta, LinesToScroll: Integer;
begin
  case Message.Msg of
    // Нативное VCL рисование: просто выводим готовый Buffer на экран!
    WM_PAINT: begin
      if (FBuffer <> nil) and (Self.Canvas <> nil) then
      begin
        // Вызываем отрисовку TGUI прямо на холст буфера
        DrawControls();
      end;
    end;

    WM_ERASEBKGND: begin
      Message.Result := 1;
      Exit; // Запрещаем Windows мерцать фоном
    end;

    // КУРСОРA ПЕРЧАТКИ
    WM_SETCURSOR: begin
      if ((GetKeyState(VK_CONTROL) and $8000) <> 0) then 
        SetCursor(LoadCursor(0, IDC_HAND))
      else
        SetCursor(LoadCursor(0, IDC_ARROW));
      Message.Result := 1; Exit; 
    end;

    // СИНХРОНИЗАЦИЯ ФОКУСА (Для сочной апельсиновой рамки)
    WM_SETFOCUS: if FLogView <> nil then
    begin
      FLogView.Focused := True;
      DrawControls();
    end;

    WM_KILLFOCUS: if FLogView <> nil then
    begin
      FLogView.Focused := False;
      DrawControls();
    end;   

    // ИДЕАЛЬНАЯ ТРАНСЛЯЦИЯ МЫШИ (По твоим канонам, без блокировки среды Delphi!)
    WM_LBUTTONDOWN, WM_LBUTTONUP, WM_RBUTTONDOWN,
    WM_RBUTTONUP, WM_MOUSEMOVE: begin
      if (FLogGUI <> nil) and (FLogView <> nil) then  
      begin
        // Собираем VCL-событие мыши
        CE := MakeMouseEvent(Message.Msg, Message.wParam);
        // Скармливаем чистые локальные координаты LoWord/HiWord из Message.lParam в TGUI
        FLogGUI.SetEvent(SmallInt(LoWord(Message.lParam)), SmallInt(HiWord(Message.lParam)), CE);
        
        if Message.Msg = WM_LBUTTONUP then
        begin
          CE.ID := etMouseClick; 
          FLogGUI.SetEvent(SmallInt(LoWord(Message.lParam)), SmallInt(HiWord(Message.lParam)), CE);
        end;
        
        DrawControls(); // Обновляем картинку буфера в памяти
      end;
    end;

    // ОБРАБОТКА КОЛЕСА МЫШИ
    WM_MOUSEWHEEL: begin
      if FLogView = nil then Exit;
      WheelDelta := SmallInt(HiWord(Message.wParam));
      LinesToScroll := 3;

      if WheelDelta > 0 then
        Dec(FLogView.ScrollPos, LinesToScroll)
      else Inc(FLogView.ScrollPos, LinesToScroll);

      if FLogView.ScrollPos < 0 then
        FLogView.ScrollPos := 0;

      if FLogView.ScrollPos > FLogView.Lines.Count - 1 then
        FLogView.ScrollPos := FLogView.Lines.Count - 1;
      DrawControls();
    end;

    WM_VSCROLL: begin
      if FLogView = nil then
      begin
        Message.Result := 0;
        Exit;
      end;
      
      // Запрашиваем у Windows актуальные параметры скроллбара
      ZeroMemory(@SI, SizeOf(TScrollInfo)); 
      SI.cbSize := SizeOf(TScrollInfo); 
      SI.fMask := SIF_ALL;
      GetScrollInfo(Handle, SB_VERT, SI);
      
      // Проверяем, что именно сделал юзер с ползунком
      case Loword(Message.wParam) of
        SB_LINEUP:     Dec(FLogView.ScrollPos);           // Кликнули на верхнюю стрелочку
        SB_LINEDOWN:   Inc(FLogView.ScrollPos);           // Кликнули на нижнюю стрелочку
        SB_PAGEUP:     Dec(FLogView.ScrollPos, SI.nPage); // Кликнули по шахте выше бегунка
        SB_PAGEDOWN:   Inc(FLogView.ScrollPos, SI.nPage); // Кликнули по шахте ниже бегунка
        SB_THUMBTRACK: FLogView.ScrollPos := SI.nTrackPos; // Зажали мышку и тащат бегунок
      end;
      
      // Жесткие предохранители границ прокрутки строк лога
      if FLogView.ScrollPos < 0 then
        FLogView.ScrollPos := 0;
      if FLogView.ScrollPos > FLogView.Lines.Count - SI.nPage then
        FLogView.ScrollPos := FLogView.Lines.Count - SI.nPage;                                                                     
        
      // Синхронизируем положение ползунка в Windows и перерисовываем буфер
      UpdateWinAPIScrollBar; 
      DrawControls();
      
      Message.Result := 0;
      Exit; // Жестко выходим, чтобы VCL не сбросила позицию ползунка!
    end;

    // РЕСАЙЗ БУФЕРА ПОД РАЗМЕРЫ ПАНЕЛИ IDE
    WM_SIZE: begin
      if FLogView <> nil then
      begin
        if FBuffer <> nil then
        begin
          FBuffer.Width := LoWord(Message.LParam);
          FBuffer.Height := HiWord(Message.LParam);
        end;
        FLogView.Move(0, 0, LoWord(Message.LParam), HiWord(Message.LParam));
        UpdateWinAPIScrollBar; 
        DrawControls();
      end;
    end;
  end;

  // ОБЯЗАТЕЛЬНО ПРОПУСКАЕМ ВСЕ СООБЩЕНИЯ (Включая мышь и фокус) ЧЕРЕЗ VCL РОДИТЕЛЯ!
  // Это заставит Delphi IDE видеть наши клики, и среда никогда не уйдет в Lockdown!
  inherited WndProc(Message);
end;

{ --- ТАЙМЕР СКАННИРОВАНИЯ ОКOН СРЕДЫ DELPHI --- }

procedure TTimerWrapper.OnScanTimerTick(Sender: TObject);
var
  I: Integer;
  MessageForm: TForm;
  DelphiTreeWnd, DelphiParentWnd: HWND;
  R: TRect;
begin
  CreatePluginMenu; // Гарантированное создание меню при старте IDE

  if not FPluginEnabled then Exit;

  MessageForm := nil; DelphiTreeWnd := 0;
  for I := 0 to Screen.FormCount - 1 do
    if SameText(Screen.Forms[I].ClassName, 'TMessageViewForm') then
    begin
      MessageForm := Screen.Forms[I];
      Break;
    end;

  if (MessageForm = nil) or (not MessageForm.Visible) then
  begin
    if MessageForm = nil then Exit;
    MessageForm.Show; Application.ProcessMessages; Exit;
  end;

  if (MessageForm <> nil) and MessageForm.Visible then
    DelphiTreeWnd := FindChildWindowByClass(MessageForm.Handle, 'TBetterHintWindowVirtualDrawTree');
  if DelphiTreeWnd = 0 then DelphiTreeWnd := FindWindowEx(0, 0, 'TBetterHintWindowVirtualDrawTree', nil);
  
  if (DelphiTreeWnd <> 0) and ((GetWindowLong(DelphiTreeWnd, GWL_STYLE) and WS_VISIBLE) <> 0) then
  begin
    DelphiParentWnd := GetParent(DelphiTreeWnd); if DelphiParentWnd = 0 then Exit;
    DelphiHintWindowWnd := DelphiTreeWnd; DelphiOriginalParentWnd := DelphiParentWnd;

    if MyLogForm = nil then MyLogForm := TLogForm.CreateNew(nil);
    if GetParent(MyLogForm.Handle) = DelphiParentWnd then
    begin if not MyLogForm.Visible then MyLogForm.Show; Exit; end;
    
    GetWindowRect(DelphiTreeWnd, R); MapWindowPoints(0, DelphiParentWnd, R, 2);
    Windows.SetParent(MyLogForm.Handle, DelphiParentWnd); Windows.ShowWindow(DelphiTreeWnd, SW_HIDE);
    MoveWindow(MyLogForm.Handle, R.Left, R.Top, R.Right - R.Left, R.Bottom - R.Top, True); MyLogForm.Show;

    RunOurDccCompiler; // Перехват компиляции из дерева без keybd_event рекурсий!
  end;
end;

{ --- ЛОГИКА ДИНАМИЧЕСКОГО И СТАТИЧЕСКОГО ОТКЛЮЧЕНИЯ ПЛАГИНА --- }

procedure TPluginWrapper.OnMenuToggleClick(Sender: TObject);
begin
  if Sender is TAction then
    SetPluginActive(not TAction(Sender).Checked);
end;

procedure LoadPluginSettings;
var
  Reg: TRegistry;
  KeyOpened: Boolean;
begin
  FPluginEnabled := True; // По умолчанию всегда включен
  Reg := TRegistry.Create(KEY_READ);   
  try
    Reg.RootKey := HKEY_CURRENT_USER; 
    // Проверяем твою родную ветку Borland
    KeyOpened := Reg.OpenKey('Software\Borland\BDS\5.0\FixIDE2007', False);
    
    // Если нет, проверяем альтернативную CodeGear
    if not KeyOpened then
      KeyOpened := Reg.OpenKey('Software\CodeGear\BDS\5.0\FixIDE2007', False);
      
    if KeyOpened then
    begin
      if Reg.ValueExists(REG_VAL_ENABLED) then
        FPluginEnabled := Reg.ReadBool(REG_VAL_ENABLED);
      Reg.CloseKey;
    end;
  finally
    Reg.Free;
  end;
end;

procedure SavePluginSettings;
var
  Reg: TRegistry;
  TargetKey: string;
begin
  Reg := TRegistry.Create(KEY_WRITE);
  try
    Reg.RootKey := HKEY_CURRENT_USER;
    
    // Проверяем, какая глобальная ветка вообще существует в системе, чтобы не срать лишними папками
    if Reg.KeyExists('Software\Borland\BDS\5.0') then
      TargetKey := 'Software\Borland\BDS\5.0\FixIDE2007'
    else
      TargetKey := 'Software\CodeGear\BDS\5.0\FixIDE2007';

    if Reg.OpenKey(TargetKey, True) then
    begin
      Reg.WriteBool(REG_VAL_ENABLED, FPluginEnabled);
      Reg.CloseKey;
    end;
  finally
    Reg.Free;
  end;
end;

procedure SetPluginActive(const Value: Boolean);
begin
  if FPluginEnabled = Value then Exit;
  FPluginEnabled := Value;
  SavePluginSettings;

  if (FActionFix <> nil) and (FActionFix.Checked <> Value) then FActionFix.Checked := Value;

  if FPluginEnabled then
  begin
    DelphiHintWindowWnd := 0; DelphiOriginalParentWnd := 0;
    if FKeyHook = 0 then
      FKeyHook := SetWindowsHookEx(WH_KEYBOARD, @KeyboardHookProc, 0, GetCurrentThreadId);
    if FTimerWrapper = nil then FTimerWrapper := TTimerWrapper.Create;
    if Assigned(FScanTimer) then FScanTimer.Enabled := True;
  end
  else
  begin
    if Assigned(FScanTimer) then FScanTimer.Enabled := False;
    if FKeyHook <> 0 then
    begin
      UnhookWindowsHookEx(FKeyHook);
      FKeyHook := 0;
    end;
    
    if (DelphiHintWindowWnd <> 0) and (DelphiOriginalParentWnd <> 0) then
    begin
      if Assigned(MyLogForm) then MyLogForm.Hide;
      Windows.SetParent(DelphiHintWindowWnd, DelphiOriginalParentWnd);
      Windows.ShowWindow(DelphiHintWindowWnd, SW_SHOW);
      Windows.InvalidateRect(DelphiOriginalParentWnd, nil, True);
      Windows.UpdateWindow(DelphiOriginalParentWnd);
    end;
  end;
end;

procedure CreatePluginMenu;
var 
  NTAServices: INTAServices; 
  ToolsMenu, NewItem: TMenuItem; 
  I: Integer;
begin
  if Supports(BorlandIDEServices, INTAServices, NTAServices) then
  begin
    if NTAServices.ActionList = nil then Exit;
    ToolsMenu := NTAServices.MainMenu.Items.Find('Tools');
    if ToolsMenu <> nil then
    begin
      // Проверяем по нашему Tag=666, чтобы не плодить дубликаты пунктов меню
      for I := 0 to ToolsMenu.Count - 1 do 
        if ToolsMenu.Items[I].Tag = 666 then Exit;

      // БЕЗОПАСНОЕ СОЗДАНИЕ: отдаем Action во владение самому списку среды!
      // Теперь среда Delphi сама правильно поставит его на учет в памяти и не упадет в обморок
      if FActionFix = nil then
      begin
        FActionFix := TAction.Create(NTAServices.ActionList); 
        FActionFix.Tag := 666;
      end;

      FActionFix.Caption := 'Log Expert (Fix WIN10)'; 
      FActionFix.Checked := FPluginEnabled; 
      FActionFix.OnExecute := FPluginWrapper.OnMenuToggleClick;

      NewItem := TMenuItem.Create(ToolsMenu); 
      NewItem.Tag := 666; 
      NewItem.Action := FActionFix; 
      
      ToolsMenu.Add(NewItem);
    end;
  end;
end;

procedure RemovePluginMenu;
var 
  NTAServices: INTAServices; 
  ToolsMenu, TargetItem: TMenuItem;
  I: Integer;
begin
  if Supports(BorlandIDEServices, INTAServices, NTAServices) then
  begin
    ToolsMenu := NTAServices.MainMenu.Items.Find('Tools');
    if ToolsMenu <> nil then
      for I := ToolsMenu.Count - 1 downto 0 do
        if ToolsMenu.Items[I].Tag = 666 then 
        begin 
          TargetItem := ToolsMenu.Items[I]; 
          ToolsMenu.Remove(TargetItem); 
          FreeAndNil(TargetItem);    
          Break; 
        end;

    // Безопасно уничтожаем экшн. Так как его Owner - это ActionList среды,
    // обычный Free автоматически вычеркнет его из всех списков Delphi без всяких RemoveAction!
    if FActionFix <> nil then
      FreeAndNil(FActionFix);
  end;
end;

procedure Register;
begin
  LoadPluginSettings;
  RegisterPackageWizard(TFixIDEWizard.Create as IOTAWizard);
  DelphiBinPath := GetDelphi2007BinPath;

  if FCompilerPipe = nil then FCompilerPipe := TPipeConsole.CreateConsole;
  if FPluginWrapper = nil then FPluginWrapper := TPluginWrapper.Create;
  if FTimerWrapper = nil then FTimerWrapper := TTimerWrapper.Create;
  
  if FScanTimer = nil then
  begin
    FScanTimer := TTimer.Create(nil);
    FScanTimer.Interval := 500;
    FScanTimer.OnTimer := FTimerWrapper.OnScanTimerTick;
    FScanTimer.Enabled := True;
  end;

  if FPluginEnabled and (FKeyHook = 0) then
    FKeyHook := SetWindowsHookEx(WH_KEYBOARD, @KeyboardHookProc, 0, GetCurrentThreadId);
end;

initialization

finalization
  RemovePluginMenu;

  if FKeyHook <> 0 then
  begin
    UnhookWindowsHookEx(FKeyHook);
    FKeyHook := 0;
  end;

  if (DelphiHintWindowWnd <> 0) and (DelphiOriginalParentWnd <> 0) then
  begin
    Windows.SetParent(DelphiHintWindowWnd, DelphiOriginalParentWnd);
    Windows.ShowWindow(DelphiHintWindowWnd, SW_SHOW);
  end;

  if FScanTimer <> nil then FreeAndNil(FScanTimer);
  if FTimerWrapper <> nil then FreeAndNil(FTimerWrapper);
  if FCompilerPipe <> nil then FreeAndNil(FCompilerPipe);
  if FPluginWrapper <> nil then FreeAndNil(FPluginWrapper);
  if MyLogForm <> nil then FreeAndNil(MyLogForm);
end.




