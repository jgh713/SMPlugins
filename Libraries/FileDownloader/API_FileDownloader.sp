#include <sourcemod>
#include <socket>

#pragma semicolon 1

new const String:PLUGIN_NAME[] = "API: File Downloader";
new const String:PLUGIN_VERSION[] = "1.1";

public Plugin:myinfo =
{
	name = PLUGIN_NAME,
	author = "hlstriker",
	description = "An API to download files.",
	version = PLUGIN_VERSION,
	url = "www.swoobles.com"
}

#define MAX_URL_LENGTH	512

/*
#define PACK_LOCATION_PARSED_HEADER		0
#define PACK_LOCATION_FILE_HANDLE		8
#define PACK_LOCATION_PACK_STRINGS		16
#define PACK_LOCATION_SUCCESS_FORWARD	24
#define PACK_LOCATION_FAILED_FORWARD	32
*/

#define PACK_LOCATION_PARSED_HEADER		0
#define PACK_LOCATION_FILE_HANDLE		1
#define PACK_LOCATION_PACK_STRINGS		2
#define PACK_LOCATION_SUCCESS_FORWARD	3
#define PACK_LOCATION_FAILED_FORWARD	4

new const String:KEY_REQUEST[]		= "req";
new const String:KEY_SAVE_PATH[]	= "save";

enum DownloadEndCode
{
	DL_END_SUCCESS,
	DL_END_FILE_NOT_FOUND,
	DL_END_SOCKET_ERROR,
	DL_END_WRITE_ERROR
};


public OnPluginStart()
{
	CreateConVar("api_file_downloader_ver", PLUGIN_VERSION, PLUGIN_NAME, FCVAR_PLUGIN|FCVAR_SPONLY|FCVAR_NOTIFY|FCVAR_PRINTABLEONLY);
}

public APLRes:AskPluginLoad2(Handle:hMyself, bool:bLate, String:szError[], iErrLen)
{
	RegPluginLibrary("file_downloader");
	
	CreateNative("FileDownloader_DownloadFile", _FileDownloader_DownloadFile);
	return APLRes_Success;
}

public _FileDownloader_DownloadFile(Handle:hPlugin, iNumParams)
{
	if(iNumParams != 4)
	{
		LogError("Invalid number of parameters.");
		return;
	}
	
	decl iLengthURL;
	if(GetNativeStringLength(1, iLengthURL) != SP_ERROR_NONE)
		return;
	
	decl iLengthSavePath;
	if(GetNativeStringLength(2, iLengthSavePath) != SP_ERROR_NONE)
		return;
	
	iLengthURL++;
	iLengthSavePath++;
	decl String:szURL[iLengthURL], String:szSavePath[iLengthSavePath];
	GetNativeString(1, szURL, iLengthURL);
	GetNativeString(2, szSavePath, iLengthSavePath);
	
	CreateDirectoryStructure(szSavePath);
	
	// Get the file handle.
	new Handle:hFile = OpenFile(szSavePath, "wb");
	
	// Create the data pack.
	new Handle:hSuccessForward;
	new Function:callback = GetNativeCell(3);
	if(callback != INVALID_FUNCTION)
	{
		hSuccessForward = CreateForward(ET_Ignore, Param_String);
		AddToForward(hSuccessForward, hPlugin, callback);
	}
	
	new Handle:hFailedForward;
	callback = GetNativeCell(4);
	if(callback != INVALID_FUNCTION)
	{
		hFailedForward = CreateForward(ET_Ignore, Param_String);
		AddToForward(hFailedForward, hPlugin, callback);
	}
	
	new Handle:hPackStrings = CreateTrie();
	SetTrieString(hPackStrings, KEY_REQUEST, "");
	SetTrieString(hPackStrings, KEY_SAVE_PATH, szSavePath);
	
	new Handle:hPack = CreateDataPack();
	WritePackCell(hPack, 0);
	WritePackCell(hPack, _:hFile);
	WritePackCell(hPack, _:hPackStrings);
	WritePackCell(hPack, _:hSuccessForward);
	WritePackCell(hPack, _:hFailedForward);
	
	// Check the file handle.
	if(hFile == INVALID_HANDLE)
	{
		LogError("Error writing to file: %s", szSavePath);
		DownloadEnded(DL_END_WRITE_ERROR, _, hPack);
		return;
	}
	
	decl String:szHostName[64], String:szLocation[128], String:szFileName[64], String:szRequest[MAX_URL_LENGTH];
	ParseURL(szURL, szHostName, sizeof(szHostName), szLocation, sizeof(szLocation), szFileName, sizeof(szFileName));
	FormatEx(szRequest, sizeof(szRequest), "GET %s/%s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\nPragma: no-cache\r\nCache-Control: no-cache\r\n\r\n", szLocation, szFileName, szHostName);
	
	SetTrieString(hPackStrings, KEY_REQUEST, szRequest);
	
	new Handle:hSocket = SocketCreate(SOCKET_TCP, OnSocketError);
	SocketSetArg(hSocket, hPack);
	SocketSetOption(hSocket, ConcatenateCallbacks, 4096);
	SocketConnect(hSocket, OnSocketConnected, OnSocketReceive, OnSocketDisconnected, szHostName, 80);
}

CreateDirectoryStructure(const String:szSavePath[])
{
	new iStrLen;
	decl String:szExplode[24][128], String:szTempPath[PLATFORM_MAX_PATH];
	new iNumExplodes = ExplodeString(szSavePath, "/", szExplode, sizeof(szExplode), sizeof(szExplode[]));
	for(new i=0; i<(iNumExplodes - 1); i++)
	{
		if(!strlen(szExplode[i]))
			continue;
		
		if(!iStrLen)
			iStrLen += strcopy(szTempPath[iStrLen], sizeof(szTempPath), szExplode[i]);
		else
			iStrLen += FormatEx(szTempPath[iStrLen], sizeof(szTempPath), "/%s", szExplode[i]);
		
		if(!iStrLen)
			continue;
		
		if(DirExists(szTempPath))
			continue;
		
		CreateDirectory(szTempPath, 509);
	}
}

public OnSocketConnected(Handle:hSocket, any:hPack)
{
	SetPackGhettoPosition(hPack, PACK_LOCATION_PACK_STRINGS);
	new Handle:hPackStrings = Handle:ReadPackCell(hPack);
	
	decl String:szRequest[MAX_URL_LENGTH];
	GetTrieString(hPackStrings, KEY_REQUEST, szRequest, sizeof(szRequest));
	
	SocketSend(hSocket, szRequest);
}

SetPackGhettoPosition(Handle:hPack, iPosition)
{
	// When SM 1.7 released it broke the increments of 8 in the pack cells.
	// Use this for a quick and extremely dirty fix.
	// TODO: Fix it properly.
	
	ResetPack(hPack, false);
	for(new i=0; i<iPosition; i++)
		ReadPackCell(hPack);
}

public OnSocketReceive(Handle:hSocket, String:szData[], const iSize, any:hPack)
{
	// Check if the HTTP header has already been parsed.
	SetPackGhettoPosition(hPack, PACK_LOCATION_PARSED_HEADER);
	new bool:bParsedHeader = bool:ReadPackCell(hPack);
	
	new iIndex;
	if(!bParsedHeader)
	{
		iIndex = StrContains(szData, "\r\n\r\n");
		if(iIndex == -1)
		{
			iIndex = 0;
		}
		else
		{
			// Check HTTP status code
			decl String:szStatusCode[32];
			strcopy(szStatusCode, sizeof(szStatusCode), szData[9]);
			if(StrContains(szStatusCode, "200 OK", false) == -1)
			{
				DownloadEnded(DL_END_FILE_NOT_FOUND, hSocket, hPack);
				return;
			}
			
			iIndex += 4;
		}
		
		SetPackGhettoPosition(hPack, PACK_LOCATION_PARSED_HEADER);
		WritePackCell(hPack, 1);
	}
	
	// Write data to file.
	SetPackGhettoPosition(hPack, PACK_LOCATION_FILE_HANDLE);
	new Handle:hFile = Handle:ReadPackCell(hPack);
	
	while(iIndex < iSize)
		WriteFileCell(hFile, szData[iIndex++], 1);
}

public OnSocketDisconnected(Handle:hSocket, any:hPack)
{
	DownloadEnded(DL_END_SUCCESS, hSocket, hPack);
}

public OnSocketError(Handle:hSocket, const iErrorType, const iErrorNum, any:hPack)
{
	DownloadEnded(DL_END_SOCKET_ERROR, hSocket, hPack);	
	LogError("Socket error: %i (Error code %i)", iErrorType, iErrorNum);
}

DownloadEnded(DownloadEndCode:code, Handle:hSocket=INVALID_HANDLE, Handle:hPack)
{
	// Get the save path.
	decl String:szSavePath[PLATFORM_MAX_PATH];
	SetPackGhettoPosition(hPack, PACK_LOCATION_PACK_STRINGS);
	new Handle:hPackStrings = ReadPackCell(hPack);
	
	if(hPackStrings != INVALID_HANDLE)
		GetTrieString(hPackStrings, KEY_SAVE_PATH, szSavePath, sizeof(szSavePath));
	else
		szSavePath[0] = '\x0';
	
	switch(code)
	{
		case DL_END_SUCCESS:
		{
			SetPackGhettoPosition(hPack, PACK_LOCATION_SUCCESS_FORWARD);
			new Handle:hHandle = ReadPackCell(hPack);
			if(hHandle != INVALID_HANDLE)
			{
				Call_StartForward(hHandle);
				Call_PushString(szSavePath);
				if(Call_Finish() != SP_ERROR_NONE)
					LogError("Error calling success forward for [%s].", szSavePath);
			}
			
			CloseSocketHandles(hSocket, hPack);
			DeleteFileIfNeeded(szSavePath);
		}
		case DL_END_FILE_NOT_FOUND, DL_END_SOCKET_ERROR, DL_END_WRITE_ERROR:
		{
			SetPackGhettoPosition(hPack, PACK_LOCATION_FAILED_FORWARD);
			new Handle:hHandle = ReadPackCell(hPack);
			if(hHandle != INVALID_HANDLE)
			{
				Call_StartForward(hHandle);
				Call_PushString(szSavePath);
				if(Call_Finish() != SP_ERROR_NONE)
					LogError("Error calling failed forward for [%s].", szSavePath);
			}
			
			CloseSocketHandles(hSocket, hPack);
			DeleteFileIfNeeded(szSavePath, true);
		}
	}
}

CloseSocketHandles(Handle:hSocket, Handle:hPack)
{
	// Close the handles.
	SetPackGhettoPosition(hPack, PACK_LOCATION_FILE_HANDLE);
	new Handle:hHandle = ReadPackCell(hPack);
	if(hHandle != INVALID_HANDLE)
		CloseHandle(hHandle);
	
	SetPackGhettoPosition(hPack, PACK_LOCATION_SUCCESS_FORWARD);
	hHandle = ReadPackCell(hPack);
	if(hHandle != INVALID_HANDLE)
		CloseHandle(hHandle);
	
	SetPackGhettoPosition(hPack, PACK_LOCATION_FAILED_FORWARD);
	hHandle = ReadPackCell(hPack);
	if(hHandle != INVALID_HANDLE)
		CloseHandle(hHandle);
	
	SetPackGhettoPosition(hPack, PACK_LOCATION_PACK_STRINGS);
	hHandle = ReadPackCell(hPack);
	if(hHandle != INVALID_HANDLE)
		CloseHandle(hHandle);
	
	if(hPack != INVALID_HANDLE)
		CloseHandle(hPack);
	
	if(hSocket != INVALID_HANDLE)
		CloseHandle(hSocket);
}

DeleteFileIfNeeded(const String:szSavePath[], bool:bForceDelete=false)
{
	// Delete the file if needed.
	new iFileSize = FileSize(szSavePath, false);
	if((bForceDelete && iFileSize != -1) || iFileSize == 0)
		DeleteFile(szSavePath);
}

/*
* Taken directly from GoD-Tony's updater plugin.
* https://forums.alliedmods.net/showthread.php?t=169095
*/
ParseURL(const String:url[], String:host[], maxHost, String:location[], maxLoc, String:filename[], maxName)
{
	// Strip url prefix.
	new idx = StrContains(url, "://");
	idx = (idx != -1) ? idx + 3 : 0;
	
	decl String:dirs[16][64];
	new total = ExplodeString(url[idx], "/", dirs, sizeof(dirs), sizeof(dirs[]));
	
	// host
	Format(host, maxHost, "%s", dirs[0]);
	
	// location
	location[0] = '\0';
	for (new i = 1; i < total - 1; i++)
	{
		Format(location, maxLoc, "%s/%s", location, dirs[i]);
	}
	
	// filename
	Format(filename, maxName, "%s", dirs[total-1]);
}