unit SE_Ship3D;

{$I GameOptions.inc}

interface

uses
  Types,
  Classes,
  Math,
  Direct3D9,
  GI_MessageLoop,
  GI_RotateImage5,
  GR_Main,
  GR_DX,
  GlobalsV;

type
  TShip3DGI = class(TRotateImage5GI)
  private
    FBankAngle: Single;
  public
    procedure Draw(ClipRect: TRect); override;
    function HitTestPixel(Point: TPoint): Boolean; override;
  end;

  { TShip3DPortraitGI — статичный 3D-портрет корабля для ангара/магазина.
    Не зависит от TShip3DGI — отдельный класс с упрощённым рендером.
    Использует те же глобальные данные модели (gVerts, gTris, ...).
    Рисует модель в изометрии с прозрачным фоном. }
  TShip3DPortraitGI = class(TObjectGI)
  private
    FModelScale: Single;  // масштаб модели относительно ClientSize
  public
    constructor Create(Owner: TObjectGI);
    procedure Draw(ClipRect: TRect); override;
  end;

{ Returns True if a ship with the given GraphKey should use the 3D renderer
  instead of the original 2D sprite. The list below maps GraphKey to the 3D
  model. To add another ship type, append its GraphKey to the SR3D_3D_HULLS
  array below.

  GraphKey is the scene-graph key like 'Ship.People.Ranger' — see
  TShip.CreateNormalGraphic in aShip.pas for the dispatch table that
  decides which GraphKey a ship gets.

  To discover the GraphKey of a particular ship: run a Windows debug build
  with DebugView running — every ship creation prints
  "SR3D ship: graphkey=<...>, use3D=<True/False>" via OutputDebugString. }
function SR3D_ShouldUse3D(const GraphKey: WideString): Boolean;

{ Register custom SR3D ships in the in-memory game data config. Call this
  AFTER MainDataConfig / GameDataConfig has been fully loaded.

  Currently registers:
    * SE.Ship.People.SR_Test  — copies SE.Ship.People.Ranger, used by the
      custom htSRTest hull type. Rendered with the 3D model thanks to
      SR3D_3D_HULLS.

  This procedure does NOT modify any .dat files — it only adds blocks to
  the in-memory TBlockParEC tree, so vanilla data is preserved. }
procedure SR3D_RegisterCustomShips;

implementation

uses
  SysUtils
  {$IFDEF MSWINDOWS}
  , Windows
  {$ENDIF}
  , EC_OKGF
  , EC_BlockPar
  , GameSystem
  ;

const
  // Texture stage state constants — not declared in the project's minimal
  // Direct3D9.pas header. Values match the official D3D9 SDK (d3d9types.h).
  // NOTE: SDL2 backend (GameGraphics.pas) only allows ONE specific
  // SetTextureStageState call: (stage=0, D3DTSS_ALPHAOP, D3DTOP_MODULATE).
  // Any other state raises "unsupported texture alpha operation".
  D3DTSS_ALPHAOP_D3D = 4;  // already declared in Direct3D9.pas but kept for clarity

type
  TD3DMatrix = array[0..3, 0..3] of Single;
  TVtx3D = record
    X, Y, Z: Single;
  end;
  TUV = record
    U, V: Single;
  end;
  TTri = record
    V0, V1, V2: Integer;
    T0, T1, T2: Integer;
    MatIdx: Integer;
    Area: Single;  // surface area, used for LOD culling (skip small tris)
  end;
  TMaterial = record
    Name: AnsiString;
    Color: Cardinal;
    HasTexture: Boolean;
    Texture: IDirect3DTexture9;
    TexPath: AnsiString;
  end;

var
  gVerts: array of TVtx3D;
  gUVs: array of TUV;
  gTris: array of TTri;
  gNormals: array of TVtx3D;
  gMats: array of TMaterial;
  gLoaded: Boolean = False;
  gLoadAttempted: Boolean = False;

const
  // SR3D: LOD threshold — skip triangles whose surface area (in normalized
  // model units, after the scl = 80/maxExt scaling) is smaller than this.
  // Set to 0 to disable LOD. Higher values = more aggressive culling.
  MIN_TRI_AREA: Single = 0.02;

{ List of ship GraphKeys that should be rendered with the 3D model.
  Add a ship's GraphKey here to enable 3D for that hull type.
  Leave the array empty to disable 3D entirely (all ships use 2D sprites).

  To discover the GraphKey of a particular ship: run a Windows debug build
  with DebugView running — every ship creation prints
  "SR3D ship: graphkey=<...>, use3D=<True/False>" via OutputDebugString.

  Currently enabled (ONLY the SR3D custom test ship — vanilla Ranger and
  RangerOldFag use their original 2D sprites):
    * Ship.People.SR_Test        — SR3D custom test ship (htSRTest hull)

  See TShip.CreateNormalGraphic in aShip.pas for the dispatch table. }
const
  SR3D_3D_HULLS: array[0..0] of WideString = (
    'Ship.People.SR_Test'
  );

function SR3D_ShouldUse3D(const GraphKey: WideString): Boolean;
var
  I: Integer;
  {$IFDEF MSWINDOWS}
  DbgLine: AnsiString;
  {$ENDIF}
begin
  Result := False;
  for I := Low(SR3D_3D_HULLS) to High(SR3D_3D_HULLS) do
  begin
    if SR3D_3D_HULLS[I] = GraphKey then
    begin
      Result := True;
      Break;
    end;
  end;
  {$IFDEF MSWINDOWS}
  DbgLine := AnsiString(Format('SR3D ship: graphkey="%s", use3D=%s',
    [string(GraphKey), BoolToStr(Result, True)]));
  OutputDebugStringA(PAnsiChar(DbgLine));
  {$ENDIF}
end;

// Internal helper: copy a block tree by deep-merging source into destination.
// MergeFrom on TBlockParEC copies all params and recursively merges child
// blocks, which is what we want for cloning SE.Ship.* definitions.
procedure SR3D_CopyBlock(Src, Dst: TBlockParEC);
begin
  Dst.MergeFrom(Src);
end;

procedure SR3D_RegisterCustomShips;
var
  ShipRoot, SrcShip, DstShip: TBlockParEC;
  {$IFDEF MSWINDOWS}
  DbgLine: AnsiString;
  {$ENDIF}
begin
  if GameDataConfig = nil then Exit;
  // Locate SE.Ship.People block (parent of Ranger, Warrior, etc.)
  ShipRoot := GameDataConfig.GetBlockByPath('SE.Ship').FindBlock('People');
  if ShipRoot = nil then
  begin
    {$IFDEF MSWINDOWS}
    OutputDebugStringA(PAnsiChar('SR3D_RegisterCustomShips: SE.Ship.People not found'));
    {$ENDIF}
    Exit;
  end;
  // Find vanilla Ranger block to use as template
  SrcShip := ShipRoot.FindBlock('Ranger');
  if SrcShip = nil then
  begin
    {$IFDEF MSWINDOWS}
    OutputDebugStringA(PAnsiChar('SR3D_RegisterCustomShips: SE.Ship.People.Ranger not found'));
    {$ENDIF}
    Exit;
  end;
  // If SR_Test already exists (e.g. modded .dat), do not overwrite.
  if ShipRoot.FindBlock('SR_Test') <> nil then
  begin
    {$IFDEF MSWINDOWS}
    OutputDebugStringA(PAnsiChar('SR3D_RegisterCustomShips: SE.Ship.People.SR_Test already exists, skipping'));
    {$ENDIF}
    Exit;
  end;
  // Add new empty block and copy Ranger's contents into it.
  DstShip := ShipRoot.AddBlockByPath('SR_Test');
  SR3D_CopyBlock(SrcShip, DstShip);
  {$IFDEF MSWINDOWS}
  DbgLine := AnsiString(Format('SR3D_RegisterCustomShips: registered SE.Ship.People.SR_Test (copied from Ranger, %d params, %d sub-blocks)',
    [DstShip.GetParamCount, DstShip.GetBlockCount]));
  OutputDebugStringA(PAnsiChar(DbgLine));
  {$ENDIF}
end;

function SR3D_MatColor(const MatName: string): Cardinal;
begin
  if MatName = 'lambert2SG' then
    Result := $FF5050DC
  else if MatName = 'lambert3SG' then
    Result := $FFDC7850
  else if MatName = 'lambert4SG' then
    Result := $FF64C850
  else
    Result := $FFBEBEBE;
end;

procedure MatIdentity(var m: TD3DMatrix);
begin
  FillChar(m, SizeOf(m), 0);
  m[0,0] := 1; m[1,1] := 1; m[2,2] := 1; m[3,3] := 1;
end;

procedure MatRotZ(var m: TD3DMatrix; a: Single);
var c, s: Single;
begin
  MatIdentity(m);
  c := Cos(a); s := Sin(a);
  m[0,0] := c; m[0,1] := s;
  m[1,0] := -s; m[1,1] := c;
end;

procedure MatRotX(var m: TD3DMatrix; a: Single);
var c, s: Single;
begin
  MatIdentity(m);
  c := Cos(a); s := Sin(a);
  m[1,1] := c; m[1,2] := s;
  m[2,1] := -s; m[2,2] := c;
end;

procedure MatMul(var r: TD3DMatrix; const a, b: TD3DMatrix);
var t: TD3DMatrix; i, j: Integer;
begin
  for i := 0 to 3 do
    for j := 0 to 3 do
      t[i,j] := a[i,0]*b[0,j] + a[i,1]*b[1,j] + a[i,2]*b[2,j] + a[i,3]*b[3,j];
  r := t;
end;

function NextTok(var S: string): string;
var
  P: Integer;
begin
  S := Trim(S);
  P := Pos(' ', S);
  if P = 0 then
  begin
    Result := S;
    S := '';
  end
  else
  begin
    Result := Copy(S, 1, P - 1);
    Delete(S, 1, P);
    S := Trim(S);
  end;
end;

function ParseFlt(const S: string): Single;
var
  Code: Integer;
begin
  Val(S, Result, Code);
  if Code <> 0 then
    Result := 0;
end;

procedure ExtractFaceIdx(const Tok: string; out VIdx, TIdx: Integer);
var
  P1, P2, Code: Integer;
  S, SubS: string;
begin
  VIdx := 0;
  TIdx := 0;
  S := Tok;
  P1 := Pos('/', S);
  if P1 = 0 then
  begin
    Val(S, VIdx, Code);
    if Code <> 0 then VIdx := 0;
  end
  else
  begin
    SubS := Copy(S, 1, P1 - 1);
    if SubS <> '' then
    begin
      Val(SubS, VIdx, Code);
      if Code <> 0 then VIdx := 0;
    end;
    S := Copy(S, P1 + 1, MaxInt);
    P2 := Pos('/', S);
    if P2 > 0 then
      SubS := Copy(S, 1, P2 - 1)
    else
      SubS := S;
    if SubS <> '' then
    begin
      Val(SubS, TIdx, Code);
      if Code <> 0 then TIdx := 0;
    end;
  end;
end;

function SR3D_FindMat(const Name: AnsiString): Integer;
var I: Integer;
begin
  Result := -1;
  for I := 0 to High(gMats) do
    if gMats[I].Name = Name then
    begin
      Result := I;
      Exit;
    end;
end;

function SR3D_GetOrCreateMat(const Name: AnsiString): Integer;
begin
  Result := SR3D_FindMat(Name);
  if Result < 0 then
  begin
    SetLength(gMats, Length(gMats) + 1);
    Result := High(gMats);
    gMats[Result].Name := Name;
    gMats[Result].Color := SR3D_MatColor(string(Name));
    gMats[Result].HasTexture := False;
    gMats[Result].Texture := nil;
    gMats[Result].TexPath := '';
  end;
end;

// Load a PNG/JPG/BMP file into a D3D9 texture using the OKGF image decoder.
function SR3D_LoadTexture(const FullPath: string): IDirect3DTexture9;
var
  FS: TFileStream;
  FileSize: Integer;
  Buf: Pointer;
  W, H: Integer;
  Ctx: POkgfReadContext;
  RGBA: PByte;
  Y: Integer;
  Tex: IDirect3DTexture9;
  Locked: TD3DLockedRect;
  {$IFDEF MSWINDOWS}
  DbgLine: string;
  {$ENDIF}
begin
  Result := nil;
  {$IFDEF MSWINDOWS}
  DbgLine := 'SR3D_LoadTexture: "' + FullPath + '"';
  if not FileExists(FullPath) then
  begin
    OutputDebugStringA(PAnsiChar(AnsiString(DbgLine + ' -> FILE NOT FOUND')));
    Exit;
  end;
  {$ENDIF}
  if not FileExists(FullPath) then Exit;
  if Direct3DDevice = nil then
  begin
    {$IFDEF MSWINDOWS}
    OutputDebugStringA(PAnsiChar(AnsiString(DbgLine + ' -> Direct3DDevice is nil')));
    {$ENDIF}
    Exit;
  end;

  FS := TFileStream.Create(FullPath, fmOpenRead or fmShareDenyWrite);
  try
    FileSize := FS.Size;
    if FileSize <= 0 then
    begin
      {$IFDEF MSWINDOWS}
      OutputDebugStringA(PAnsiChar(AnsiString(DbgLine + ' -> empty file')));
      {$ENDIF}
      Exit;
    end;
    GetMem(Buf, FileSize);
    try
      FS.Read(Buf^, FileSize);

      Ctx := BeginImageRead(Buf, FileSize, W, H);
      if Ctx = nil then
      begin
        {$IFDEF MSWINDOWS}
        OutputDebugStringA(PAnsiChar(AnsiString(Format('%s -> BeginImageRead FAILED (size=%d)', [DbgLine, FileSize]))));
        {$ENDIF}
        Exit;
      end;
      if (W <= 0) or (H <= 0) then Exit;

      GetMem(RGBA, W * H * 4);
      try
        if ReadImagePixels(Ctx, RGBA, W * 4,
            $FF0000, $FF00, $FF, $FF000000, 4) = 0 then
        begin
          {$IFDEF MSWINDOWS}
          OutputDebugStringA(PAnsiChar(AnsiString(Format('%s -> ReadImagePixels returned 0 (%dx%d)', [DbgLine, W, H]))));
          {$ENDIF}
          Exit;
        end;

        if Direct3DDevice.CreateTexture(W, H, 1, 0,
            D3DFMT_A8R8G8B8, D3DPOOL_MANAGED, Tex, nil) <> 0 then
        begin
          {$IFDEF MSWINDOWS}
          OutputDebugStringA(PAnsiChar(AnsiString(Format('%s -> CreateTexture FAILED (%dx%d)', [DbgLine, W, H]))));
          {$ENDIF}
          Exit;
        end;

        if Tex.LockRect(0, Locked, nil, 0) = 0 then
        begin
          for Y := 0 to H - 1 do
            System.Move(
              PByte(RGBA)[Y * W * 4],
              PByte(Locked.Bits)[Y * Locked.Pitch],
              W * 4);
          Tex.UnlockRect(0);
          Result := Tex;
          {$IFDEF MSWINDOWS}
          OutputDebugStringA(PAnsiChar(AnsiString(Format('%s -> OK %dx%d', [DbgLine, W, H]))));
          {$ENDIF}
        end
        else
        begin
          Tex := nil;
          {$IFDEF MSWINDOWS}
          OutputDebugStringA(PAnsiChar(AnsiString(DbgLine + ' -> LockRect FAILED')));
          {$ENDIF}
        end;
      finally
        FreeMem(RGBA);
      end;
    finally
      FreeMem(Buf);
    end;
  finally
    FS.Free;
  end;
end;

procedure SR3D_LoadMTL(const MTLPath: string);
var
  F: TextFile;
  Line, Tok, TexName, TexPath, BaseDir, ObjNameNoExt: string;
  CurIdx: Integer;
  R, G, B: Single;
  FallbackTex: IDirect3DTexture9;
  FallbackTried: Boolean;
  {$IFDEF MSWINDOWS}
  DbgMsg: string;
  {$ENDIF}

  function TryLoad(const P: string): IDirect3DTexture9;
  begin
    Result := nil;
    if P = '' then Exit;
    if not FileExists(P) then Exit;
    Result := SR3D_LoadTexture(P);
  end;

begin
  if not FileExists(MTLPath) then Exit;

  BaseDir := ExtractFilePath(MTLPath);
  ObjNameNoExt := ChangeFileExt(ExtractFileName(MTLPath), '');
  FallbackTex := nil;
  FallbackTried := False;
  CurIdx := -1;
  {$IFDEF MSWINDOWS}
  DbgMsg := '';
  {$ENDIF}

  AssignFile(F, MTLPath);
  {$I-}
  Reset(F);
  {$I+}
  if IOResult <> 0 then Exit;

  while not EOF(F) do
  begin
    ReadLn(F, Line);
    Line := Trim(Line);
    if (Line = '') or (Line[1] = '#') then Continue;

    if Copy(Line, 1, 7) = 'newmtl ' then
    begin
      Delete(Line, 1, 7);
      Line := Trim(Line);
      CurIdx := SR3D_GetOrCreateMat(AnsiString(Line));
    end
    else if Copy(Line, 1, 3) = 'Kd ' then
    begin
      Delete(Line, 1, 3);
      Line := Trim(Line);
      Tok := NextTok(Line); R := ParseFlt(Tok);
      Tok := NextTok(Line); G := ParseFlt(Tok);
      Tok := NextTok(Line); B := ParseFlt(Tok);
      if CurIdx >= 0 then
        gMats[CurIdx].Color := $FF000000 or
          (Cardinal(Round(R * 255)) shl 16) or
          (Cardinal(Round(G * 255)) shl 8) or
          Cardinal(Round(B * 255));
    end
    else if Copy(Line, 1, 7) = 'map_Kd ' then
    begin
      Delete(Line, 1, 7);
      TexName := Trim(Line);
      while (TexName <> '') and (TexName[1] = '-') do
      begin
        NextTok(TexName);
        NextTok(TexName);
      end;
      if CurIdx >= 0 then
      begin
        gMats[CurIdx].TexPath := AnsiString(TexName);

        TexPath := BaseDir + TexName;
        gMats[CurIdx].Texture := TryLoad(TexPath);
        if gMats[CurIdx].Texture = nil then
          gMats[CurIdx].Texture := TryLoad(BaseDir + ExtractFileName(TexName));

        if gMats[CurIdx].Texture = nil then
        begin
          if not FallbackTried then
          begin
            FallbackTried := True;
            FallbackTex := TryLoad(BaseDir + ObjNameNoExt + '.png');
          end;
          gMats[CurIdx].Texture := FallbackTex;
        end;

        gMats[CurIdx].HasTexture := gMats[CurIdx].Texture <> nil;

        {$IFDEF MSWINDOWS}
        if not gMats[CurIdx].HasTexture then
          DbgMsg := DbgMsg + 'MTL tex MISSING: ' + TexName + #13#10
        else if gMats[CurIdx].Texture = FallbackTex then
          DbgMsg := DbgMsg + 'MTL tex FALLBACK: ' + TexName + ' -> ' + ObjNameNoExt + '.png' + #13#10;
        {$ENDIF}
      end;
    end;
  end;
  CloseFile(F);

  {$IFDEF MSWINDOWS}
  if DbgMsg <> '' then
    OutputDebugStringA(PAnsiChar(AnsiString(DbgMsg)));
  {$ENDIF}
end;

// Find first *.png (case-insensitive) in the given directory and load it
// as a D3D9 texture. Returns nil if no PNG is found or loading fails.
function SR3D_FindFirstPngInDir(const Dir: string): IDirect3DTexture9;
var
  SR: TSearchRec;
  Found: Boolean;
  FullPath: string;
begin
  Result := nil;
  Found := False;
  // Try lowercase extension first, then uppercase.
  if SysUtils.FindFirst(Dir + '*.png', faAnyFile, SR) = 0 then
    Found := True
  else if SysUtils.FindFirst(Dir + '*.PNG', faAnyFile, SR) = 0 then
    Found := True;
  if Found then
  begin
    FullPath := Dir + SR.Name;
    SysUtils.FindClose(SR);
    Result := SR3D_LoadTexture(FullPath);
  end;
end;

procedure SR3D_LoadModel;
var
  Path, MTLName, BaseDir, MTLPath: string;
  F: TextFile;
  Line, Tok: string;
  I, VI, TI: Integer;
  FaceVerts: array of Integer;
  FaceUVs: array of Integer;
  FaceCount: Integer;
  vCount, tCount, vtCount: Integer;
  minB, maxB: TVtx3D;
  cx, cy, cz, maxExt, scl: Single;
  v0, v1, v2: TVtx3D;
  nx, ny, nz, nlen: Single;
  Paths: array[0..9] of string;
  DebugMsg: string;
  CurMatIdx: Integer;
  CurMatName: string;
  FallbackPath: string;
  FallbackTex2: IDirect3DTexture9;
  {$IFDEF MSWINDOWS}
  TexInfo: string;
  {$ENDIF}
begin
  if gLoaded or gLoadAttempted then Exit;
  gLoadAttempted := True;

  Paths[0] := 'data/models/1405_plane.obj';
  Paths[1] := 'data\models\1405_plane.obj';
  Paths[2] := '..\data\models\1405_plane.obj';
  Paths[3] := '..\..\data\models\1405_plane.obj';
  Paths[4] := 'data/models/1405_Plane.obj';
  Paths[5] := 'D:\SR3D\SpaceRangersHD_FPC\data\models\1405_plane.obj';
  Paths[6] := 'D:\SR3D\SpaceRangersHD_FPC\data\models\1405_Plane.obj';
  Paths[7] := 'D:\SR3D\SpaceRangersHD_FPC\data\models\1405 Plane.obj';
  Paths[8] := 'D:\Games\Space Rangers HD A War Apart\data\models\1405_plane.obj';
  Paths[9] := '1405_Plane.obj';

  Path := '';
  DebugMsg := 'SR3D: searching for obj file...' + #13#10;
  for I := 0 to 9 do
  begin
    if FileExists(Paths[I]) then
    begin
      Path := Paths[I];
      DebugMsg := DebugMsg + 'FOUND: ' + Paths[I] + #13#10;
      Break;
    end
    else
    begin
      DebugMsg := DebugMsg + 'not found: ' + Paths[I] + #13#10;
    end;
  end;

  if Path = '' then
  begin
    {$IFDEF MSWINDOWS}
    MessageBox(0, PChar(DebugMsg), 'SR3D LoadModel', MB_OK or MB_ICONWARNING);
    {$ENDIF}
    Exit;
  end;

  SetLength(gVerts, 0);
  SetLength(gUVs, 0);
  SetLength(gTris, 0);
  SetLength(gNormals, 0);
  SetLength(gMats, 0);
  SetLength(FaceVerts, 64);
  SetLength(FaceUVs, 64);
  vCount := 0;
  vtCount := 0;
  tCount := 0;
  CurMatIdx := -1;
  CurMatName := '';
  MTLName := '';

  AssignFile(F, Path);
  {$I-}
  Reset(F);
  {$I+}
  if IOResult <> 0 then Exit;

  while not EOF(F) do
  begin
    ReadLn(F, Line);
    Line := Trim(Line);
    if (Line = '') or (Line[1] = '#') then Continue;

    if Copy(Line, 1, 7) = 'mtllib ' then
    begin
      Delete(Line, 1, 7);
      MTLName := Trim(Line);
      Continue;
    end;

    if Copy(Line, 1, 7) = 'usemtl ' then
    begin
      Delete(Line, 1, 7);
      CurMatName := Trim(Line);
      CurMatIdx := SR3D_GetOrCreateMat(AnsiString(CurMatName));
      Continue;
    end;

    if (Length(Line) >= 2) and (Line[1] = 'v') and (Line[2] = ' ') then
    begin
      Delete(Line, 1, 1);
      Line := Trim(Line);

      Tok := NextTok(Line); cx := ParseFlt(Tok);
      Tok := NextTok(Line); cy := ParseFlt(Tok);
      Tok := NextTok(Line); cz := ParseFlt(Tok);

      SetLength(gVerts, vCount + 1);
      gVerts[vCount].X := cx;
      gVerts[vCount].Y := cy;
      gVerts[vCount].Z := cz;
      Inc(vCount);
      Continue;
    end;

    if (Length(Line) >= 3) and (Line[1] = 'v') and (Line[2] = 't') and (Line[3] = ' ') then
    begin
      Delete(Line, 1, 3);
      Line := Trim(Line);

      Tok := NextTok(Line); cx := ParseFlt(Tok);
      Tok := NextTok(Line); cy := ParseFlt(Tok);

      SetLength(gUVs, vtCount + 1);
      gUVs[vtCount].U := cx;
      gUVs[vtCount].V := cy;
      Inc(vtCount);
      Continue;
    end;

    if (Length(Line) >= 2) and (Line[1] = 'f') and (Line[2] = ' ') then
    begin
      Delete(Line, 1, 1);
      Line := Trim(Line);

      FaceCount := 0;
      while Length(Line) > 0 do
      begin
        Tok := NextTok(Line);
        ExtractFaceIdx(Tok, VI, TI);
        if VI > 0 then
        begin
          if FaceCount >= Length(FaceVerts) then
          begin
            SetLength(FaceVerts, FaceCount + 32);
            SetLength(FaceUVs, FaceCount + 32);
          end;
          FaceVerts[FaceCount] := VI - 1;
          FaceUVs[FaceCount] := TI - 1;
          Inc(FaceCount);
        end;
      end;

      if FaceCount >= 3 then
      begin
        for I := 1 to FaceCount - 2 do
        begin
          SetLength(gTris, tCount + 1);
          SetLength(gNormals, tCount + 1);
          gTris[tCount].V0 := FaceVerts[0];
          gTris[tCount].V1 := FaceVerts[I];
          gTris[tCount].V2 := FaceVerts[I + 1];

          if FaceUVs[0] >= 0 then gTris[tCount].T0 := FaceUVs[0] else gTris[tCount].T0 := -1;
          if FaceUVs[I] >= 0 then gTris[tCount].T1 := FaceUVs[I] else gTris[tCount].T1 := -1;
          if FaceUVs[I+1] >= 0 then gTris[tCount].T2 := FaceUVs[I+1] else gTris[tCount].T2 := -1;

          gTris[tCount].MatIdx := CurMatIdx;

          if (gTris[tCount].V0 < vCount) and
             (gTris[tCount].V1 < vCount) and
             (gTris[tCount].V2 < vCount) then
          begin
            v0 := gVerts[gTris[tCount].V0];
            v1 := gVerts[gTris[tCount].V1];
            v2 := gVerts[gTris[tCount].V2];
            nx := (v1.Y - v0.Y) * (v2.Z - v0.Z) - (v1.Z - v0.Z) * (v2.Y - v0.Y);
            ny := (v1.Z - v0.Z) * (v2.X - v0.X) - (v1.X - v0.X) * (v2.Z - v0.Z);
            nz := (v1.X - v0.X) * (v2.Y - v0.Y) - (v1.Y - v0.Y) * (v2.X - v0.X);
            nlen := Sqrt(nx*nx + ny*ny + nz*nz);
            if nlen > 0.001 then
            begin
              nx := nx / nlen;
              ny := ny / nlen;
              nz := nz / nlen;
            end;
            gNormals[tCount].X := nx;
            gNormals[tCount].Y := ny;
            gNormals[tCount].Z := nz;
          end;

          Inc(tCount);
        end;
      end;
    end;
  end;
  CloseFile(F);

  // === Parse MTL file ===
  BaseDir := ExtractFilePath(Path);
  MTLPath := '';
  if MTLName <> '' then
  begin
    if FileExists(BaseDir + MTLName) then
      MTLPath := BaseDir + MTLName
    else if FileExists(BaseDir + ExtractFileName(MTLName)) then
      MTLPath := BaseDir + ExtractFileName(MTLName);
  end;
  if MTLPath = '' then
  begin
    MTLPath := ChangeFileExt(Path, '.mtl');
    if not FileExists(MTLPath) then MTLPath := '';
  end;
  if MTLPath <> '' then
    SR3D_LoadMTL(MTLPath);

  // === AGGRESSIVE FALLBACK ===
  // If after parsing the MTL there are materials without a texture, try
  // multiple strategies to find ANY usable PNG:
  //   1. <objname>.png next to the .obj (e.g. 1405_Plane.png)
  //   2. <objname>.PNG (case-insensitive on Windows, but be explicit)
  //   3. First *.png file found in the same directory as the .obj
  // Apply the discovered texture to ALL materials that have no texture.
  // This guarantees that if ANY png sits next to the .obj, ships will be
  // textured — so we can verify the UV/render pipeline works.
  FallbackTex2 := nil;
  FallbackPath := ChangeFileExt(Path, '.png');
  if FileExists(FallbackPath) then
    FallbackTex2 := SR3D_LoadTexture(FallbackPath);
  if FallbackTex2 = nil then
  begin
    // Try uppercase extension
    FallbackPath := ChangeFileExt(Path, '.PNG');
    if FileExists(FallbackPath) then
      FallbackTex2 := SR3D_LoadTexture(FallbackPath);
  end;
  if FallbackTex2 = nil then
    FallbackTex2 := SR3D_FindFirstPngInDir(ExtractFilePath(Path));
  if FallbackTex2 <> nil then
  begin
    for I := 0 to High(gMats) do
    begin
      if gMats[I].Texture = nil then
      begin
        gMats[I].Texture := FallbackTex2;
        gMats[I].HasTexture := True;
        if gMats[I].TexPath = '' then
          gMats[I].TexPath := AnsiString(ExtractFileName(FallbackPath));
      end;
    end;
  end;

  // === Center & scale model ===
  if vCount > 0 then
  begin
    minB := gVerts[0];
    maxB := gVerts[0];
    for I := 1 to vCount - 1 do
    begin
      if gVerts[I].X < minB.X then minB.X := gVerts[I].X;
      if gVerts[I].Y < minB.Y then minB.Y := gVerts[I].Y;
      if gVerts[I].Z < minB.Z then minB.Z := gVerts[I].Z;
      if gVerts[I].X > maxB.X then maxB.X := gVerts[I].X;
      if gVerts[I].Y > maxB.Y then maxB.Y := gVerts[I].Y;
      if gVerts[I].Z > maxB.Z then maxB.Z := gVerts[I].Z;
    end;

    cx := (minB.X + maxB.X) / 2;
    cy := (minB.Y + maxB.Y) / 2;
    cz := (minB.Z + maxB.Z) / 2;

    maxExt := maxB.X - minB.X;
    if maxB.Y - minB.Y > maxExt then maxExt := maxB.Y - minB.Y;
    if maxB.Z - minB.Z > maxExt then maxExt := maxB.Z - minB.Z;

    if maxExt > 0 then
      // Normalize model so its largest dimension is ~80 pixels — close to
      // the original 2D sprite size (64). Tune this value to make the
      // ship bigger or smaller.
      scl := 80.0 / maxExt
    else
      scl := 1.0;

    for I := 0 to vCount - 1 do
    begin
      gVerts[I].X := (gVerts[I].X - cx) * scl;
      gVerts[I].Y := (gVerts[I].Y - cy) * scl;
      gVerts[I].Z := (gVerts[I].Z - cz) * scl;
    end;
  end;

  gLoaded := True;

  {$IFDEF MSWINDOWS}
  TexInfo := '';
  for I := 0 to High(gMats) do
  begin
    TexInfo := TexInfo + Format('  Mat %d: %s' + #13#10 +
      '    color=$%.8X' + #13#10 +
      '    texpath="%s"' + #13#10 +
      '    hastexture=%s' + #13#10,
      [I, string(gMats[I].Name), gMats[I].Color,
       string(gMats[I].TexPath),
       BoolToStr(gMats[I].HasTexture, True)]);
  end;

  MessageBox(0,
    PChar(Format('SR3D model loaded OK!' + #13#10 +
                 'Path: %s' + #13#10 +
                 'MTL: %s' + #13#10 +
                 'Vertices: %d' + #13#10 +
                 'UVs: %d' + #13#10 +
                 'Triangles: %d' + #13#10 +
                 'Materials: %d' + #13#10 +
                 'MaxExt: %.1f' + #13#10 +
                 'Scale: %.3f' + #13#10 +
                 'Materials list:' + #13#10 + '%s',
      [Path, MTLPath, vCount, vtCount, tCount, Length(gMats), maxExt, scl, TexInfo])),
    'SR3D LoadModel', MB_OK or MB_ICONINFORMATION);
  {$ENDIF}
end;

procedure SR3D_SortTrisByMat;
var
  I, J: Integer;
  Tmp: TTri;
  TmpN: TVtx3D;
begin
  for I := 1 to High(gTris) do
  begin
    J := I;
    while (J > 0) and (gTris[J].MatIdx < gTris[J-1].MatIdx) do
    begin
      Tmp := gTris[J];
      gTris[J] := gTris[J-1];
      gTris[J-1] := Tmp;
      TmpN := gNormals[J];
      gNormals[J] := gNormals[J-1];
      gNormals[J-1] := TmpN;
      Dec(J);
    end;
  end;
end;

// Compute surface area of each triangle for LOD culling. Triangle area is
// 0.5 * |(V1-V0) × (V2-V0)| — half the magnitude of the cross product.
// Called once after model load. The areas are stored in gTris[].Area and
// read in TShip3DGI.Draw to skip triangles smaller than MIN_TRI_AREA.
procedure SR3D_ComputeTriAreas;
var
  I: Integer;
  V0, V1, V2: TVtx3D;
  CX, CY, CZ: Single;
begin
  for I := 0 to High(gTris) do
  begin
    V0 := gVerts[gTris[I].V0];
    V1 := gVerts[gTris[I].V1];
    V2 := gVerts[gTris[I].V2];
    // Cross product of (V1-V0) and (V2-V0)
    CX := (V1.Y - V0.Y) * (V2.Z - V0.Z) - (V1.Z - V0.Z) * (V2.Y - V0.Y);
    CY := (V1.Z - V0.Z) * (V2.X - V0.X) - (V1.X - V0.X) * (V2.Z - V0.Z);
    CZ := (V1.X - V0.X) * (V2.Y - V0.Y) - (V1.Y - V0.Y) * (V2.X - V0.X);
    // Area = 0.5 * |cross|
    gTris[I].Area := 0.5 * Sqrt(CX*CX + CY*CY + CZ*CZ);
  end;
end;

function TShip3DGI.HitTestPixel(Point: TPoint): Boolean;
const
  // Half-size of the ship sprite in logical coordinates. The model is
  // centered on AbsolutePosition with a footprint of ~150 units; we add
  // some slack so clicks at the edge of wings/nose still register.
  HIT_RADIUS = 100;
var
  Local: TPoint;
begin
  // Convert screen point to logical (pre-zoom) coordinates first, so the
  // hit radius is independent of zoom level.
  Local := ScreenToLogicalPoint(Point);
  Result := (Abs(Local.X - AbsolutePosition.X) <= HIT_RADIUS) and
            (Abs(Local.Y - AbsolutePosition.Y) <= HIT_RADIUS);
end;

procedure TShip3DGI.Draw(ClipRect: TRect);
var
  AngleRad: Single;
  RotZMat, RotXMat, RotZBank, WorldMat, CamMat: TD3DMatrix;
  CX, CY: Single;
  I, TCount, OutIdx: Integer;
  RenderVerts: array of TScreenVertexGR;
  OutMats: array of Integer;
  Vx, Vy, Vz, Wx, Wy: Single;
  NX, NY, NZ: Single;
  CNz: Single;
  Wnx, Wny, Wnz: Single;
  Intensity: Single;
  R, G, B: Byte;
  BaseColor: Cardinal;
  CurMatIdx, RunStart, RunCount: Integer;
  CurTex: IDirect3DTexture9;
  // Static overhead lighting
  LightX, LightY, LightZ: Single;
  Ambient: Single;
  // BigClip — restore previous scissor after drawing
  OldClip: TRect;
  BigClip: TRect;
  ScreenHalfW, ScreenHalfH: Integer;
  Scale: Single;
begin
  if not HardwareRenderingEnabled then
  begin
    inherited Draw(ClipRect);
    Exit;
  end;

  {$IFDEF MSWINDOWS}
  OutputDebugStringA(PAnsiChar(AnsiString(Format(
    'SR3D Draw: abspos=(%d,%d) scale=%.3f clip=(L=%d,T=%d,R=%d,B=%d) clientsize=(%d,%d) tris=%d',
    [AbsolutePosition.X, AbsolutePosition.Y, Scale,
     ClipRect.Left, ClipRect.Top, ClipRect.Right, ClipRect.Bottom,
     ClientSize.X, ClientSize.Y,
     Length(gTris)]))));
  {$ENDIF}

  // NOTE: no HitTestBounds culling here — parent DrawControl already did it
  // before calling us, and our UpdateHitTestBounds returns a generous bbox
  // so we don't get wrongly discarded when zoomed out.

  if not gLoaded then
  begin
    SR3D_LoadModel;
    if not gLoaded then
    begin
      inherited Draw(ClipRect);
      Exit;
    end;
    SR3D_SortTrisByMat;
    SR3D_ComputeTriAreas;
  end;

  AngleRad := (Angle / 256) * 2 * Pi - Pi / 2;
  // Use AbsolutePosition as the center — it already accounts for parent
  // ChildWorldScale / scroll. HitTestBounds is the 2D-sprite box and
  // would give a wrong center after zoom changes.
  CX := AbsolutePosition.X;
  CY := AbsolutePosition.Y;

  // === Zoom-aware BigClip ===
  // The ship itself stays at a fixed pixel size (we don't scale Wx/Wy by
  // zoom). But the SCISSOR rect must cover the full visible area at every
  // zoom level, otherwise the ship gets clipped when zoomed out.
  //
  // We build BigClip in LOGICAL coordinates centered on the ship:
  //   half_screen_in_logical = (screen_pixels / Scale) / 2
  // Then SDL2 backend's RasterClipRect scales it back to screen pixels.
  if (Parent <> nil) then
    Scale := Parent.ChildWorldScale
  else
    Scale := 1.0;

  // === Gentle rocking animation (like original 2D sprites) ===
  // Original ships bob slightly left-right at all times — the sprite itself
  // is animated. We reproduce that with a small sinusoidal roll driven by
  // game tick. No bank-on-turn anymore: the ship stays level while turning,
  // only the heading (AngleRad) changes.
  //
  // Amplitude is ~6°, period ~2.2s at 60fps. Use GameTickCount (ms).
  FBankAngle := Sin((GameTickCount mod 2200) / 2200.0 * 2 * Pi) * (Pi / 30);

  // === World matrix ===
  MatRotZ(RotZBank, FBankAngle);
  MatRotX(RotXMat, -Pi / 3);
  MatRotZ(RotZMat, AngleRad + 3 * Pi / 2);
  WorldMat := RotZBank;
  MatMul(WorldMat, WorldMat, RotXMat);
  MatMul(WorldMat, WorldMat, RotZMat);
  // Camera-only matrix (no bank) — used for back-face culling only.
  CamMat := RotXMat;
  MatMul(CamMat, CamMat, RotZMat);

  TCount := Length(gTris);
  if TCount = 0 then Exit;

  // === Static "sun overhead" lighting ===
  // Original ships have their lighting BAKED INTO the sprite — the sun is
  // effectively directly overhead and the light never moves.
  //
  // We use a near-vertical light in MODEL space: +Y is the top of the
  // hull, with a small -Z bias so the sun is "above and slightly behind
  // the nose". After the camera tilt (-60° around X), top-facing polygons
  // end up facing the camera and slightly toward the top of the screen —
  // that's exactly what we want lit.
  //
  // If lighting looks wrong (ship in shadow), the most likely cause is
  // inverted winding — try flipping the sign of LightY.
  LightX := 0;
  LightY := -0.95;  // NEGATIVE because OBJ winding may put normals inside-out
  LightZ := 0.30;   // opposite sign of Z too (consistent with the flip)
  Ambient := 0.50;  // high ambient so we can SEE the ship while debugging

  SetLength(RenderVerts, TCount * 3);
  SetLength(OutMats, TCount);

  // Project all vertices and compute per-vertex color.
  // We do BACK-FACE CULLING: skip triangles whose normal in screen space
  // has CNz <= 0 (pointing away from camera). Without a Z-buffer, drawing
  // both front and back faces causes the back faces to bleed through and
  // the lighting appears washed out / wrong side lit.
  OutIdx := 0;
  for I := 0 to TCount - 1 do
  begin
    // Original model-space normal.
    NX := gNormals[I].X;
    NY := gNormals[I].Y;
    NZ := gNormals[I].Z;

    // Back-face culling: use CamMat (camera + screen rotation, NO bank) to
    // get the normal's Z in screen space. Skip triangles whose normal
    // points AWAY from the camera (back faces). Without this, both top
    // and bottom faces render and z-fighting creates black patches where
    // bottom faces bleed through the top.
    //
    // Sign convention: with our camera tilted -60° around X, top-facing
    // polygons (model +Y normal) end up with CNz > 0 in screen space
    // (they face toward the camera). Bottom-facing polygons get CNz < 0.
    // We keep CNz > 0 (visible), cull CNz <= 0 (away from camera).
    CNz := NX * CamMat[0,2] + NY * CamMat[1,2] + NZ * CamMat[2,2];
    if CNz <= 0.02 then Continue;

    // LOD: skip triangles whose surface area (computed once at load time)
    // is below MIN_TRI_AREA. Small triangles contribute little to the
    // silhouette and removing them cuts vertex transform cost.
    if (MIN_TRI_AREA > 0) and (gTris[I].Area < MIN_TRI_AREA) then Continue;

    // Lighting: world-space normal (RotZBank only — bank rotates the ship
    // in the world, so it changes lighting; but screen rotation does NOT
    // change world lighting, so we skip RotXMat/RotZMat here).
    Wnx := NX * RotZBank[0,0] + NY * RotZBank[1,0] + NZ * RotZBank[2,0];
    Wny := NX * RotZBank[0,1] + NY * RotZBank[1,1] + NZ * RotZBank[2,1];
    Wnz := NX * RotZBank[0,2] + NY * RotZBank[1,2] + NZ * RotZBank[2,2];

    // Lambertian diffuse in world space: N_world · L_world.
    // Light direction is fixed in the world (sun position), so when the
    // ship rotates in 2D, only the bank changes the lighting — not the
    // heading. This is the desired "light comes from the sun, not the
    // screen" behaviour.
    Intensity := Wnx * LightX + Wny * LightY + Wnz * LightZ;
    if Intensity < 0 then Intensity := 0;
    Intensity := Ambient + Intensity * 0.70;
    // Skylight: a small fill from above (world +Z) so top-facing polygons
    // are not pitch-black when the sun is low on the horizon. Use the
    // world-space normal Z (Wnz), not screen-space CNz, so the fill is
    // anchored to the world too.
    if Wnz > 0 then
      Intensity := Intensity + Wnz * 0.15;
    if Intensity > 1.0 then Intensity := 1.0;

    // === Project 3 vertices through full world matrix (with bank) ===
    // NOTE: We do NOT multiply Wx/Wy by Scale (ChildWorldScale) — in this
    // game zoom is camera distance, not object scaling. Objects stay at
    // their fixed pixel size; only their on-screen position changes.
    // Vertex 0
    Vx := gVerts[gTris[I].V0].X;
    Vy := gVerts[gTris[I].V0].Y;
    Vz := gVerts[gTris[I].V0].Z;
    Wx := Vx * WorldMat[0,0] + Vy * WorldMat[1,0] + Vz * WorldMat[2,0] + WorldMat[3,0];
    Wy := Vx * WorldMat[0,1] + Vy * WorldMat[1,1] + Vz * WorldMat[2,1] + WorldMat[3,1];
    RenderVerts[OutIdx].X := CX + Wx;
    RenderVerts[OutIdx].Y := CY + Wy;
    RenderVerts[OutIdx].Z := 1.0;
    RenderVerts[OutIdx].RHW := 1.0;
    if gTris[I].T0 >= 0 then
    begin
      RenderVerts[OutIdx].U := gUVs[gTris[I].T0].U;
      RenderVerts[OutIdx].V := 1.0 - gUVs[gTris[I].T0].V;
    end
    else
    begin
      RenderVerts[OutIdx].U := 0;
      RenderVerts[OutIdx].V := 0;
    end;

    // Vertex 1
    Vx := gVerts[gTris[I].V1].X;
    Vy := gVerts[gTris[I].V1].Y;
    Vz := gVerts[gTris[I].V1].Z;
    Wx := Vx * WorldMat[0,0] + Vy * WorldMat[1,0] + Vz * WorldMat[2,0] + WorldMat[3,0];
    Wy := Vx * WorldMat[0,1] + Vy * WorldMat[1,1] + Vz * WorldMat[2,1] + WorldMat[3,1];
    RenderVerts[OutIdx+1].X := CX + Wx;
    RenderVerts[OutIdx+1].Y := CY + Wy;
    RenderVerts[OutIdx+1].Z := 1.0;
    RenderVerts[OutIdx+1].RHW := 1.0;
    if gTris[I].T1 >= 0 then
    begin
      RenderVerts[OutIdx+1].U := gUVs[gTris[I].T1].U;
      RenderVerts[OutIdx+1].V := 1.0 - gUVs[gTris[I].T1].V;
    end
    else
    begin
      RenderVerts[OutIdx+1].U := 0;
      RenderVerts[OutIdx+1].V := 0;
    end;

    // Vertex 2
    Vx := gVerts[gTris[I].V2].X;
    Vy := gVerts[gTris[I].V2].Y;
    Vz := gVerts[gTris[I].V2].Z;
    Wx := Vx * WorldMat[0,0] + Vy * WorldMat[1,0] + Vz * WorldMat[2,0] + WorldMat[3,0];
    Wy := Vx * WorldMat[0,1] + Vy * WorldMat[1,1] + Vz * WorldMat[2,1] + WorldMat[3,1];
    RenderVerts[OutIdx+2].X := CX + Wx;
    RenderVerts[OutIdx+2].Y := CY + Wy;
    RenderVerts[OutIdx+2].Z := 1.0;
    RenderVerts[OutIdx+2].RHW := 1.0;
    if gTris[I].T2 >= 0 then
    begin
      RenderVerts[OutIdx+2].U := gUVs[gTris[I].T2].U;
      RenderVerts[OutIdx+2].V := 1.0 - gUVs[gTris[I].T2].V;
    end
    else
    begin
      RenderVerts[OutIdx+2].U := 0;
      RenderVerts[OutIdx+2].V := 0;
    end;

    // (Intensity was already computed above using world-space normal and
    // world-space light direction. See the lighting block near the top of
    // the loop.)

    if (gTris[I].MatIdx >= 0) and (gTris[I].MatIdx <= High(gMats)) then
      BaseColor := gMats[gTris[I].MatIdx].Color
    else
      BaseColor := $FFBEBEBE;

    R := (BaseColor shr 0)  and $FF;
    G := (BaseColor shr 8)  and $FF;
    B := (BaseColor shr 16) and $FF;
    R := Round(R * Intensity);
    G := Round(G * Intensity);
    B := Round(B * Intensity);
    BaseColor := $FF000000 or (B shl 16) or (G shl 8) or R;

    RenderVerts[OutIdx].Color := BaseColor;
    RenderVerts[OutIdx+1].Color := BaseColor;
    RenderVerts[OutIdx+2].Color := BaseColor;

    // IMPORTANT: keep the material idx in lockstep with OutIdx so the
    // render-batching loop below groups contiguous triangles by material.
    // gTris is already sorted by MatIdx, so culled triangles just shrink
    // each material run — the run boundaries still align.
    OutMats[OutIdx div 3] := gTris[I].MatIdx;
    Inc(OutIdx, 3);
  end;

  if OutIdx = 0 then Exit;
  TCount := OutIdx div 3;

  // === Render triangles grouped by material ===
  // SDL2 backend only allows ONE specific SetTextureStageState call:
  //   (stage=0, D3DTSS_ALPHAOP, D3DTOP_MODULATE)
  // We rely on its default behavior:
  //   * texture bound  -> texture * diffuse (MODULATE)
  //   * nil texture    -> solid diffuse color (SELECTARG2)
  Direct3DDevice.SetFVF(D3DFVF_XYZRHW or D3DFVF_DIFFUSE or D3DFVF_TEX1);
  Direct3DDevice.SetTextureStageState(0, D3DTSS_ALPHAOP, D3DTOP_MODULATE);

  // === BigClip ===
  // Save current scissor, then set a BIG scissor in LOGICAL coordinates
  // centered on the ship. This matches the trick used by TRingBackImageGI
  // for planet rings — it lets the 3D model render at any zoom level
  // without being clipped by the parent panel's narrow logical ClipRect.
  //
  // IMPORTANT: SDL2 backend's RasterClipRect multiplies the scissor by
  // GameGraphicsTransform.Scale (which includes ChildWorldScale via the
  // parent's RasterScaleX). So we must pass a rect in LOGICAL coords —
  // the same coordinate space ClipRect comes in. Using GameScreenRect
  // (screen pixels) directly DOES NOT WORK because it gets scaled
  // wrongly. We build a rect ±half-screen / Scale centered on the ship.
  Direct3DDevice.GetScissorRect(OldClip);
  if Scale > 0.001 then
  begin
    ScreenHalfW := Round(GameScreenWidth / Scale / 2) + 100;
    ScreenHalfH := Round(GameScreenHeight / Scale / 2) + 100;
  end
  else
  begin
    ScreenHalfW := 2000;
    ScreenHalfH := 2000;
  end;
  BigClip.Left   := AbsolutePosition.X - ScreenHalfW;
  BigClip.Right  := AbsolutePosition.X + ScreenHalfW;
  BigClip.Top    := AbsolutePosition.Y - ScreenHalfH;
  BigClip.Bottom := AbsolutePosition.Y + ScreenHalfH;
  Direct3DDevice.SetScissorRect(@BigClip);

  I := 0;
  while I < TCount do
  begin
    CurMatIdx := OutMats[I];
    RunStart := I;
    while (I < TCount) and (OutMats[I] = CurMatIdx) do
      Inc(I);
    RunCount := I - RunStart;

    if (CurMatIdx >= 0) and (CurMatIdx <= High(gMats)) then
      CurTex := gMats[CurMatIdx].Texture
    else
      CurTex := nil;

    Direct3DDevice.SetTexture(0, CurTex);

    Direct3DDevice.DrawPrimitiveUP(
      D3DPT_TRIANGLELIST,
      RunCount,
      @RenderVerts[RunStart * 3],
      SizeOf(TScreenVertexGR));
  end;

  Direct3DDevice.SetTexture(0, nil);

  // Restore previous scissor so other rendering is not affected.
  Direct3DDevice.SetScissorRect(@OldClip);
end;

{ === TShip3DPortraitGI === }

constructor TShip3DPortraitGI.Create(Owner: TObjectGI);
begin
  inherited Create(Owner);
  FModelScale := 0.8;  // модель занимает 80% размера окна
end;

procedure TShip3DPortraitGI.Draw(ClipRect: TRect);
const
  // Статичный свет сверху (как в космосе, но без покачивания).
  // +Y — верх модели, лёгкий наклон к хвосту.
  LightX: Single = 0;
  LightY: Single = -0.95;
  LightZ: Single = 0.30;
  Ambient: Single = 0.40;
var
  RotXMat, RotZMat, WorldMat, CamMat: TD3DMatrix;
  CX, CY: Single;
  I, TCount, OutIdx: Integer;
  RenderVerts: array of TScreenVertexGR;
  OutMats: array of Integer;
  Vx, Vy, Vz, Wx, Wy: Single;
  NX, NY, NZ: Single;
  CNz: Single;
  Wnx, Wny, Wnz: Single;
  Intensity: Single;
  R, G, B: Byte;
  BaseColor: Cardinal;
  CurMatIdx, RunStart, RunCount: Integer;
  CurTex: IDirect3DTexture9;
  MinSize: Integer;
begin
  {$IFDEF MSWINDOWS}
  OutputDebugStringA(PAnsiChar(AnsiString(Format(
    'SR3D Portrait Draw: clientsize=(%d,%d) active=%s gloaded=%s tris=%d',
    [ClientSize.X, ClientSize.Y, BoolToStr(Active, True),
     BoolToStr(gLoaded, True), Length(gTris)]))));
  {$ENDIF}
  if not HardwareRenderingEnabled then Exit;
  if not gLoaded then
  begin
    SR3D_LoadModel;
    if not gLoaded then Exit;
    SR3D_SortTrisByMat;
    SR3D_ComputeTriAreas;
  end;

  // Если размер окна 0 — не рисуем
  if (ClientSize.X <= 0) or (ClientSize.Y <= 0) then Exit;

  // Центр окна = центр модели
  CX := ClientSize.X / 2;
  CY := ClientSize.Y / 2;

  // Масштаб модели: модель нормирована до ~80 единиц, окно ~128px.
  // FModelScale = 0.8 → модель занимает 80% окна.
  MinSize := ClientSize.X;
  if ClientSize.Y < MinSize then MinSize := ClientSize.Y;
  // scl_model — масштаб из модельных единиц в пиксели окна
  // модель после загрузки ~80 единиц, хотим ~MinSize*FModelScale пикселей
  // → scale = (MinSize*FModelScale) / 80
  // но модель уже отнормирована (scl=80 в LoadModel), так что просто:
  // умножим Wx, Wy на (MinSize / 100) * FModelScale

  // Изометрия: поворот вокруг X (камера сверху-сбоку) + лёгкий поворот Z
  MatRotX(RotXMat, -Pi / 4);       // -45° наклон камеры (изометрия)
  MatRotZ(RotZMat, Pi / 6);        // +30° поворот модели для изометрии
  WorldMat := RotXMat;
  MatMul(WorldMat, WorldMat, RotZMat);
  CamMat := WorldMat;  // для culling та же матрица

  TCount := Length(gTris);
  if TCount = 0 then Exit;

  SetLength(RenderVerts, TCount * 3);
  SetLength(OutMats, TCount);

  OutIdx := 0;
  for I := 0 to TCount - 1 do
  begin
    NX := gNormals[I].X;
    NY := gNormals[I].Y;
    NZ := gNormals[I].Z;

    // Back-face culling (как в космосе)
    CNz := NX * CamMat[0,2] + NY * CamMat[1,2] + NZ * CamMat[2,2];
    if CNz <= 0.02 then Continue;

    // LOD
    if (MIN_TRI_AREA > 0) and (gTris[I].Area < MIN_TRI_AREA) then Continue;

    // Освещение (статичное, как в космосе)
    Wnx := NX * WorldMat[0,0] + NY * WorldMat[1,0] + NZ * WorldMat[2,0];
    Wny := NX * WorldMat[0,1] + NY * WorldMat[1,1] + NZ * WorldMat[2,1];
    Wnz := NX * WorldMat[0,2] + NY * WorldMat[1,2] + NZ * WorldMat[2,2];
    Intensity := Wnx * LightX + Wny * LightY + Wnz * LightZ;
    if Intensity < 0 then Intensity := 0;
    Intensity := Ambient + Intensity * 0.70;
    if Intensity > 1.0 then Intensity := 1.0;

    // Вершины
    Vx := gVerts[gTris[I].V0].X;
    Vy := gVerts[gTris[I].V0].Y;
    Vz := gVerts[gTris[I].V0].Z;
    Wx := Vx * WorldMat[0,0] + Vy * WorldMat[1,0] + Vz * WorldMat[2,0];
    Wy := Vx * WorldMat[0,1] + Vy * WorldMat[1,1] + Vz * WorldMat[2,1];
    RenderVerts[OutIdx].X := CX + Wx * (MinSize / 100) * FModelScale;
    RenderVerts[OutIdx].Y := CY + Wy * (MinSize / 100) * FModelScale;
    RenderVerts[OutIdx].Z := 1.0;
    RenderVerts[OutIdx].RHW := 1.0;
    if gTris[I].T0 >= 0 then
    begin
      RenderVerts[OutIdx].U := gUVs[gTris[I].T0].U;
      RenderVerts[OutIdx].V := 1.0 - gUVs[gTris[I].T0].V;
    end
    else
    begin
      RenderVerts[OutIdx].U := 0;
      RenderVerts[OutIdx].V := 0;
    end;

    Vx := gVerts[gTris[I].V1].X;
    Vy := gVerts[gTris[I].V1].Y;
    Vz := gVerts[gTris[I].V1].Z;
    Wx := Vx * WorldMat[0,0] + Vy * WorldMat[1,0] + Vz * WorldMat[2,0];
    Wy := Vx * WorldMat[0,1] + Vy * WorldMat[1,1] + Vz * WorldMat[2,1];
    RenderVerts[OutIdx+1].X := CX + Wx * (MinSize / 100) * FModelScale;
    RenderVerts[OutIdx+1].Y := CY + Wy * (MinSize / 100) * FModelScale;
    RenderVerts[OutIdx+1].Z := 1.0;
    RenderVerts[OutIdx+1].RHW := 1.0;
    if gTris[I].T1 >= 0 then
    begin
      RenderVerts[OutIdx+1].U := gUVs[gTris[I].T1].U;
      RenderVerts[OutIdx+1].V := 1.0 - gUVs[gTris[I].T1].V;
    end
    else
    begin
      RenderVerts[OutIdx+1].U := 0;
      RenderVerts[OutIdx+1].V := 0;
    end;

    Vx := gVerts[gTris[I].V2].X;
    Vy := gVerts[gTris[I].V2].Y;
    Vz := gVerts[gTris[I].V2].Z;
    Wx := Vx * WorldMat[0,0] + Vy * WorldMat[1,0] + Vz * WorldMat[2,0];
    Wy := Vx * WorldMat[0,1] + Vy * WorldMat[1,1] + Vz * WorldMat[2,1];
    RenderVerts[OutIdx+2].X := CX + Wx * (MinSize / 100) * FModelScale;
    RenderVerts[OutIdx+2].Y := CY + Wy * (MinSize / 100) * FModelScale;
    RenderVerts[OutIdx+2].Z := 1.0;
    RenderVerts[OutIdx+2].RHW := 1.0;
    if gTris[I].T2 >= 0 then
    begin
      RenderVerts[OutIdx+2].U := gUVs[gTris[I].T2].U;
      RenderVerts[OutIdx+2].V := 1.0 - gUVs[gTris[I].T2].V;
    end
    else
    begin
      RenderVerts[OutIdx+2].U := 0;
      RenderVerts[OutIdx+2].V := 0;
    end;

    // Цвет
    if (gTris[I].MatIdx >= 0) and (gTris[I].MatIdx <= High(gMats)) then
      BaseColor := gMats[gTris[I].MatIdx].Color
    else
      BaseColor := $FFBEBEBE;
    R := (BaseColor shr 0)  and $FF;
    G := (BaseColor shr 8)  and $FF;
    B := (BaseColor shr 16) and $FF;
    R := Round(R * Intensity);
    G := Round(G * Intensity);
    B := Round(B * Intensity);
    BaseColor := $FF000000 or (B shl 16) or (G shl 8) or R;
    RenderVerts[OutIdx].Color := BaseColor;
    RenderVerts[OutIdx+1].Color := BaseColor;
    RenderVerts[OutIdx+2].Color := BaseColor;

    OutMats[OutIdx div 3] := gTris[I].MatIdx;
    Inc(OutIdx, 3);
  end;

  if OutIdx = 0 then Exit;
  TCount := OutIdx div 3;

  // Рендер (без BigClip — ангар сам клипает через ClipRect)
  Direct3DDevice.SetFVF(D3DFVF_XYZRHW or D3DFVF_DIFFUSE or D3DFVF_TEX1);
  Direct3DDevice.SetTextureStageState(0, D3DTSS_ALPHAOP, D3DTOP_MODULATE);

  I := 0;
  while I < TCount do
  begin
    CurMatIdx := OutMats[I];
    RunStart := I;
    while (I < TCount) and (OutMats[I] = CurMatIdx) do
      Inc(I);
    RunCount := I - RunStart;
    if (CurMatIdx >= 0) and (CurMatIdx <= High(gMats)) then
      CurTex := gMats[CurMatIdx].Texture
    else
      CurTex := nil;
    Direct3DDevice.SetTexture(0, CurTex);
    Direct3DDevice.DrawPrimitiveUP(
      D3DPT_TRIANGLELIST, RunCount,
      @RenderVerts[RunStart * 3], SizeOf(TScreenVertexGR));
  end;
  Direct3DDevice.SetTexture(0, nil);
end;

end.
