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
  public
    procedure Draw(ClipRect: TRect); override;
  end;

implementation

uses
  SysUtils
  {$IFDEF MSWINDOWS}
  , Windows
  {$ENDIF}
  ;

type
  TD3DMatrix = array[0..3, 0..3] of Single;
  TVtx3D = record
    X, Y, Z: Single;
  end;
  TTri = record
    V0, V1, V2: Integer;
  end;

var
  gVerts: array of TVtx3D;
  gTris: array of TTri;
  gNormals: array of TVtx3D;
  gLoaded: Boolean = False;
  gLoadAttempted: Boolean = False;

// ===== Matrix math =====
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

// ===== Tokenizer =====
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

function ExtractVertIdx(const Tok: string): Integer;
var
  P: Integer;
  S: string;
begin
  S := Tok;
  P := Pos('/', S);
  if P > 0 then
    S := Copy(S, 1, P - 1);
  Val(S, Result, P);
  if P <> 0 then
    Result := 0;
end;

// ===== OBJ Loader =====
procedure SR3D_LoadModel;
var
  Path: string;
  F: TextFile;
  Line, Tok: string;
  I, P, VI, FC: Integer;
  FaceVerts: array of Integer;
  FaceCount: Integer;
  vCount, tCount: Integer;
  minB, maxB: TVtx3D;
  cx, cy, cz, maxExt, scl: Single;
  v0, v1, v2: TVtx3D;
  nx, ny, nz, nlen: Single;
  Paths: array[0..8] of string;
  DebugMsg: string;
begin
  if gLoaded or gLoadAttempted then Exit;
  gLoadAttempted := True;

  // Multiple search paths — relative + absolute, both underscore and space
  Paths[0] := 'data/models/1405_plane.obj';
  Paths[1] := 'data\models\1405_plane.obj';
  Paths[2] := '..\data\models\1405_plane.obj';
  Paths[3] := '..\..\data\models\1405_plane.obj';
  Paths[4] := 'D:\SR3D\SpaceRangersHD_FPC\data\models\1405_plane.obj';
  Paths[5] := 'D:\SR3D\SpaceRangersHD_FPC\data\models\1405 Plane.obj';
  Paths[6] := 'D:\Games\Space Rangers HD A War Apart\data\models\1405_plane.obj';
  Paths[7] := '1405_plane.obj';
  Paths[8] := '1405 Plane.obj';

  Path := '';
  DebugMsg := 'SR3D: searching for obj file...' + #13#10;
  for I := 0 to 8 do
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
  SetLength(gTris, 0);
  SetLength(gNormals, 0);
  SetLength(FaceVerts, 64);
  vCount := 0;
  tCount := 0;

  AssignFile(F, Path);
  {$I-}
  Reset(F);
  {$I+}
  if IOResult <> 0 then Exit;

  while not EOF(F) do
  begin
    ReadLn(F, Line);
    Line := Trim(Line);

    if (Length(Line) >= 2) and (Line[1] = 'v') and (Line[2] = ' ') then
    begin
      Delete(Line, 1, 1);
      Line := Trim(Line);

      Tok := NextTok(Line);
      cx := ParseFlt(Tok);
      Tok := NextTok(Line);
      cy := ParseFlt(Tok);
      Tok := NextTok(Line);
      cz := ParseFlt(Tok);

      SetLength(gVerts, vCount + 1);
      gVerts[vCount].X := cx;
      gVerts[vCount].Y := cy;
      gVerts[vCount].Z := cz;
      Inc(vCount);
    end
    else if (Length(Line) >= 2) and (Line[1] = 'f') and (Line[2] = ' ') then
    begin
      Delete(Line, 1, 1);
      Line := Trim(Line);

      FaceCount := 0;
      while Length(Line) > 0 do
      begin
        Tok := NextTok(Line);
        VI := ExtractVertIdx(Tok);
        if VI > 0 then
        begin
          if FaceCount >= Length(FaceVerts) then
            SetLength(FaceVerts, FaceCount + 32);
          FaceVerts[FaceCount] := VI - 1;
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

          // Compute face normal
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

  // Normalize: center at origin + scale
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
      scl := 150.0 / maxExt
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
  MessageBox(0,
    PChar(Format('SR3D model loaded OK!' + #13#10 +
                 'Path: %s' + #13#10 +
                 'Vertices: %d' + #13#10 +
                 'Triangles: %d' + #13#10 +
                 'MaxExt: %.1f' + #13#10 +
                 'Scale: %.3f', [Path, vCount, tCount, maxExt, scl])),
    'SR3D LoadModel', MB_OK or MB_ICONINFORMATION);
  {$ENDIF}
end;

// ===== Draw =====
procedure TShip3DGI.Draw(ClipRect: TRect);
var
  AngleRad: Single;
  RotZMat, RotXMat, WorldMat: TD3DMatrix;
  CX, CY: Single;
  I, TCount: Integer;
  RenderVerts: array of TScreenVertexGR;
  Vx, Vy, Vz, Wx, Wy, Wz: Single;
  NX, NY, NZ: Single;
  Intensity: Single;
  R, G, B: Byte;
  BaseColor: Cardinal;
begin
  if not HardwareRenderingEnabled then
  begin
    inherited Draw(ClipRect);
    Exit;
  end;

  if (HitTestBounds.Right < ClipRect.Left) or (HitTestBounds.Left > ClipRect.Right) or
     (HitTestBounds.Bottom < ClipRect.Top) or (HitTestBounds.Top > ClipRect.Bottom) then Exit;

  // Load model lazily
  if not gLoaded then
  begin
    SR3D_LoadModel;
    if not gLoaded then
    begin
      inherited Draw(ClipRect);
      Exit;
    end;
  end;

  AngleRad := (Angle / 256) * 2 * Pi - Pi / 2;
  CX := (HitTestBounds.Right + HitTestBounds.Left) / 2;
  CY := (HitTestBounds.Bottom + HitTestBounds.Top) / 2;

  // Build world matrix: World = RotZ(shipAngle) * RotX(-90°)
  // RotX(-90°) puts model's +Z axis onto screen's +Y (so the nose,
  // which is at +Z in the .obj, becomes "forward" in screen plane).
  MatRotZ(RotZMat, AngleRad);
  MatRotX(RotXMat, -Pi / 2);  // -90°: lay model flat (Z -> Y screen)
  WorldMat := RotZMat;
  MatMul(WorldMat, WorldMat, RotXMat);

  TCount := Length(gTris);
  if TCount = 0 then Exit;

  // Pre-allocate render vertex array
  SetLength(RenderVerts, TCount * 3);

  for I := 0 to TCount - 1 do
  begin
    // --- Vertex 0 ---
    Vx := gVerts[gTris[I].V0].X;
    Vy := gVerts[gTris[I].V0].Y;
    Vz := gVerts[gTris[I].V0].Z;
    Wx := Vx * WorldMat[0,0] + Vy * WorldMat[1,0] + Vz * WorldMat[2,0] + WorldMat[3,0];
    Wy := Vx * WorldMat[0,1] + Vy * WorldMat[1,1] + Vz * WorldMat[2,1] + WorldMat[3,1];
    RenderVerts[I*3].X := CX + Wx;
    RenderVerts[I*3].Y := CY + Wy;
    RenderVerts[I*3].Z := 1.0;
    RenderVerts[I*3].RHW := 1.0;
    RenderVerts[I*3].U := 0;
    RenderVerts[I*3].V := 0;

    // --- Vertex 1 ---
    Vx := gVerts[gTris[I].V1].X;
    Vy := gVerts[gTris[I].V1].Y;
    Vz := gVerts[gTris[I].V1].Z;
    Wx := Vx * WorldMat[0,0] + Vy * WorldMat[1,0] + Vz * WorldMat[2,0] + WorldMat[3,0];
    Wy := Vx * WorldMat[0,1] + Vy * WorldMat[1,1] + Vz * WorldMat[2,1] + WorldMat[3,1];
    RenderVerts[I*3+1].X := CX + Wx;
    RenderVerts[I*3+1].Y := CY + Wy;
    RenderVerts[I*3+1].Z := 1.0;
    RenderVerts[I*3+1].RHW := 1.0;
    RenderVerts[I*3+1].U := 0;
    RenderVerts[I*3+1].V := 0;

    // --- Vertex 2 ---
    Vx := gVerts[gTris[I].V2].X;
    Vy := gVerts[gTris[I].V2].Y;
    Vz := gVerts[gTris[I].V2].Z;
    Wx := Vx * WorldMat[0,0] + Vy * WorldMat[1,0] + Vz * WorldMat[2,0] + WorldMat[3,0];
    Wy := Vx * WorldMat[0,1] + Vy * WorldMat[1,1] + Vz * WorldMat[2,1] + WorldMat[3,1];
    RenderVerts[I*3+2].X := CX + Wx;
    RenderVerts[I*3+2].Y := CY + Wy;
    RenderVerts[I*3+2].Z := 1.0;
    RenderVerts[I*3+2].RHW := 1.0;
    RenderVerts[I*3+2].U := 0;
    RenderVerts[I*3+2].V := 0;

    // --- Lighting: rotate normal to world space, then dot with light ---
    NX := gNormals[I].X;
    NY := gNormals[I].Y;
    NZ := gNormals[I].Z;
    Wx := NX * WorldMat[0,0] + NY * WorldMat[1,0] + NZ * WorldMat[2,0];
    Wy := NX * WorldMat[0,1] + NY * WorldMat[1,1] + NZ * WorldMat[2,1];
    Wz := NX * WorldMat[0,2] + NY * WorldMat[1,2] + NZ * WorldMat[2,2];

    // Light direction: (0, 0.5, 0.866) — from front-above
    Intensity := Wy * 0.5 + Wz * 0.866;
    if Intensity < 0.25 then Intensity := 0.25;
    if Intensity > 1.0 then Intensity := 1.0;

    // Base color: neutral gray with flat shading
    R := Round(190 * Intensity);
    G := Round(190 * Intensity);
    B := Round(190 * Intensity);
    BaseColor := $FF000000 or (B shl 16) or (G shl 8) or R;

    RenderVerts[I*3].Color := BaseColor;
    RenderVerts[I*3+1].Color := BaseColor;
    RenderVerts[I*3+2].Color := BaseColor;
  end;

  // Render all triangles in one batch
  Direct3DDevice.SetTexture(0, nil);
  Direct3DDevice.SetFVF(D3DFVF_XYZRHW or D3DFVF_DIFFUSE or D3DFVF_TEX1);
  Direct3DDevice.DrawPrimitiveUP(D3DPT_TRIANGLELIST, TCount, @RenderVerts[0], SizeOf(TScreenVertexGR));
end;

end.