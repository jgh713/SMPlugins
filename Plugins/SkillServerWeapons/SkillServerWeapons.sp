#include <sourcemod>
#include <sdkhooks>
#include <sdktools_functions>
#include <sdktools_entinput>
#include <cstrike>
#include "../../Libraries/ClientCookies/client_cookies"
#include <hls_color_chat>

#pragma semicolon 1

new const String:PLUGIN_NAME[] = "Skill Server Weapons";
new const String:PLUGIN_VERSION[] = "1.0";

public Plugin:myinfo =
{
	name = PLUGIN_NAME,
	author = "hlstriker",
	description = "Skill server weapons.",
	version = PLUGIN_VERSION,
	url = "www.swoobles.com"
}

#define WEAPON_TEAM_ANY		-1
#define WEAPON_TEAM_NONE	0	// Use WEAPON_TEAM_NONE for weapons that break due to inventory loadout.
#define WEAPON_TEAM_T		CS_TEAM_T
#define WEAPON_TEAM_CT		CS_TEAM_CT

#define MAX_WEAPON_NAME_LEN			24
#define MAX_WEAPON_ENT_NAME_LEN		49

#define SetWeaponOwnerSerial(%1,%2)		SetEntProp(%1, Prop_Data, "m_iMaxHealth", %2)
#define GetWeaponOwnerSerial(%1)		GetEntProp(%1, Prop_Data, "m_iMaxHealth")

#define EF_NODRAW	32

#define CATEGORY_HIDE_WEAPONS	-1

enum WeaponCategory
{
	CATEGORY_UNKNOWN = 0,
	CATEGORY_KNIFE,
	CATEGORY_PISTOLS,
	NUM_WEAPON_CATS
};

new Handle:g_aWeapons;
enum _:WeaponData
{
	String:WEAPON_NAME[MAX_WEAPON_NAME_LEN],
	String:WEAPON_ENT_NAME[MAX_WEAPON_ENT_NAME_LEN],
	WEAPON_TEAM,
	WeaponCategory:WEAPON_CATEGORY
};


new g_iDroppedWeaponRef[MAXPLAYERS+1][NUM_WEAPON_CATS];
new bool:g_bIgnoreDropHook[MAXPLAYERS+1];

new g_iNumKnives;
new g_iNumPistols;

new g_iDefaultIndex_KnifeT;
new g_iDefaultIndex_KnifeCT;
new g_iDefaultIndex_PistolT;
new g_iDefaultIndex_PistolCT;

#define USE_DEFAULT_WEAPON	-1
new g_iKnifeIndex[MAXPLAYERS+1];
new g_iPistolIndex[MAXPLAYERS+1];

new bool:g_bShouldHideWeapons[MAXPLAYERS+1];


public OnPluginStart()
{
	CreateConVar("skill_server_weapons_ver", PLUGIN_VERSION, PLUGIN_NAME, FCVAR_PLUGIN|FCVAR_SPONLY|FCVAR_NOTIFY|FCVAR_PRINTABLEONLY);
	
	new Handle:cvar_mp_give_player_c4 = FindConVar("mp_give_player_c4");
	if(cvar_mp_give_player_c4 != INVALID_HANDLE)
	{
		HookConVarChange(cvar_mp_give_player_c4, OnConVarChanged);
		SetConVarBool(cvar_mp_give_player_c4, false);
	}
	
	g_aWeapons = CreateArray(WeaponData);
	BuildWeaponsArray();
	
	RegConsoleCmd("sm_gun", OnWeaponSelect, "Opens the weapon selection menu.");
	RegConsoleCmd("sm_guns", OnWeaponSelect, "Opens the weapon selection menu.");
	RegConsoleCmd("sm_weapon", OnWeaponSelect, "Opens the weapon selection menu.");
	RegConsoleCmd("sm_weapons", OnWeaponSelect, "Opens the weapon selection menu.");
	RegConsoleCmd("sm_knife", OnWeaponSelect, "Opens the weapon selection menu.");
	RegConsoleCmd("sm_knives", OnWeaponSelect, "Opens the weapon selection menu.");
	RegConsoleCmd("sm_ws", OnWeaponSelect, "Opens the weapon selection menu.");
}

public Action:OnWeaponSelect(iClient, iArgNum)
{
	if(!iClient)
		return Plugin_Handled;
	
	DisplayMenu_CategorySelect(iClient);
	return Plugin_Handled;
}

DisplayMenu_CategorySelect(iClient)
{
	if(!ClientCookies_HaveCookiesLoaded(iClient))
	{
		CPrintToChat(iClient, "{red}Unavailable, try again in a few seconds.");
		return;
	}
	
	new Handle:hMenu = CreateMenu(MenuHandle_CategorySelect);
	SetMenuTitle(hMenu, "Select a category");
	
	decl String:szInfo[4];
	IntToString(_:CATEGORY_KNIFE, szInfo, sizeof(szInfo));
	AddMenuItem(hMenu, szInfo, "Knives");
	
	IntToString(_:CATEGORY_PISTOLS, szInfo, sizeof(szInfo));
	AddMenuItem(hMenu, szInfo, "Pistols");
	
	AddMenuItem(hMenu, "", "", ITEMDRAW_SPACER);
	AddMenuItem(hMenu, "", "", ITEMDRAW_SPACER);
	
	IntToString(_:CATEGORY_HIDE_WEAPONS, szInfo, sizeof(szInfo));
	if(g_bShouldHideWeapons[iClient])
		AddMenuItem(hMenu, szInfo, "Unhide weapons");
	else
		AddMenuItem(hMenu, szInfo, "Hide weapons");
	
	if(!DisplayMenu(hMenu, iClient, 0))
		CPrintToChat(iClient, "{red}There are no weapon categories.");
}

public MenuHandle_CategorySelect(Handle:hMenu, MenuAction:action, iParam1, iParam2)
{
	if(action == MenuAction_End)
	{
		CloseHandle(hMenu);
		return;
	}
	
	if(action != MenuAction_Select)
		return;
	
	decl String:szInfo[4];
	GetMenuItem(hMenu, iParam2, szInfo, sizeof(szInfo));
	
	new iCategory = StringToInt(szInfo);
	if(iCategory == CATEGORY_HIDE_WEAPONS)
	{
		g_bShouldHideWeapons[iParam1] = !g_bShouldHideWeapons[iParam1];
		ClientCookies_SetCookie(iParam1, CC_TYPE_SKILL_SERVER_WEAPONS_HIDE, g_bShouldHideWeapons[iParam1]);
		
		SetViewModelVisibility(iParam1);
		
		DisplayMenu_CategorySelect(iParam1);
		return;
	}
	
	DisplayMenu_WeaponSelect(iParam1, iCategory);
}

DisplayMenu_WeaponSelect(iClient, iCategory)
{
	new iArraySize = GetArraySize(g_aWeapons);
	if(!iArraySize)
	{
		CPrintToChat(iClient, "{red}There are no weapons in this category.");
		DisplayMenu_CategorySelect(iClient);
		return;
	}
	
	new Handle:hMenu = CreateMenu(MenuHandle_WeaponSelect);
	SetMenuTitle(hMenu, "Select a weapon");
	
	decl String:szInfo[9], eWeaponData[WeaponData];
	FormatEx(szInfo, sizeof(szInfo), "%i~%i", iCategory, USE_DEFAULT_WEAPON);
	AddMenuItem(hMenu, szInfo, "Default");
	
	for(new i=0; i<iArraySize; i++)
	{
		if(!GetArrayArray(g_aWeapons, i, eWeaponData))
			continue;
		
		if(iCategory != _:eWeaponData[WEAPON_CATEGORY])
			continue;
		
		FormatEx(szInfo, sizeof(szInfo), "%i~%i", iCategory, i);
		AddMenuItem(hMenu, szInfo, eWeaponData[WEAPON_NAME]);
	}
	
	SetMenuExitBackButton(hMenu, true);
	if(!DisplayMenu(hMenu, iClient, 0))
	{
		CPrintToChat(iClient, "{red} This category has no weapons.");
		DisplayMenu_CategorySelect(iClient);
		return;
	}
}

public MenuHandle_WeaponSelect(Handle:hMenu, MenuAction:action, iParam1, iParam2)
{
	if(action == MenuAction_End)
	{
		CloseHandle(hMenu);
		return;
	}
	
	if(action == MenuAction_Cancel)
	{
		if(iParam2 == MenuCancel_ExitBack)
		{
			DisplayMenu_CategorySelect(iParam1);
			return;
		}
		
		return;
	}
	
	if(action != MenuAction_Select)
		return;
	
	decl String:szInfo[9], String:szBuffers[2][9];
	GetMenuItem(hMenu, iParam2, szInfo, sizeof(szInfo));
	ExplodeString(szInfo, "~", szBuffers, sizeof(szBuffers), sizeof(szBuffers[]));
	
	new iCategory = StringToInt(szBuffers[0]);
	new iIndex = StringToInt(szBuffers[1]);
	
	switch(iCategory)
	{
		case CATEGORY_KNIFE:
		{
			g_iKnifeIndex[iParam1] = iIndex;
			ClientCookies_SetCookie(iParam1, CC_TYPE_SKILL_SERVER_WEAPONS_KNIFE_INDEX, iIndex);
		}
		case CATEGORY_PISTOLS:
		{
			g_iPistolIndex[iParam1] = iIndex;
			ClientCookies_SetCookie(iParam1, CC_TYPE_SKILL_SERVER_WEAPONS_PISTOL_INDEX, iIndex);
		}
	}
	
	if(iIndex == USE_DEFAULT_WEAPON)
	{
		CPrintToChat(iParam1, "{red}The next time you respawn you will use your default.");
		return;
	}
	
	GivePlayerWeapon(iParam1, iIndex, true);
}

GivePlayerWeapon(iClient, iIndex, bool:bStripWeaponsOfSameCategory)
{
	decl eWeaponData[WeaponData];
	GetArrayArray(g_aWeapons, iIndex, eWeaponData);
	
	// Strip weapons of the same category if needed.
	if(bStripWeaponsOfSameCategory)
		StripClientWeaponsOfCategoryType(iClient, _:eWeaponData[WEAPON_CATEGORY]);
	
	// Give the weapon.
	new iClientTeam = GetClientTeam(iClient);
	
	if(eWeaponData[WEAPON_TEAM] != WEAPON_TEAM_ANY)
		SetEntProp(iClient, Prop_Send, "m_iTeamNum", eWeaponData[WEAPON_TEAM]);
	
	new iWeapon = GivePlayerItemCustom(iClient, eWeaponData[WEAPON_ENT_NAME]);
	SetEntProp(iClient, Prop_Send, "m_iTeamNum", iClientTeam);
	
	SDKHook(iWeapon, SDKHook_ReloadPost, OnWeaponReload);
	
	return iWeapon;
}

public OnWeaponReload(iWeapon, bool:bSuccess)
{
	new iClient = GetEntPropEnt(iWeapon, Prop_Data, "m_hOwnerEntity");
	if(!(1 <= iClient <= MaxClients))
		return;
	
	GivePlayerAmmo(iClient, 500, GetEntProp(iWeapon, Prop_Data, "m_iPrimaryAmmoType"), true);
}

GivePlayerItemCustom(iClient, const String:szClassName[])
{
	new iEnt = GivePlayerItem(iClient, szClassName);
	
	/*
	* 	Sometimes GivePlayerItem() will call EquipPlayerWeapon() directly.
	* 	Other times which seems to be directly after stripping weapons or player spawn EquipPlayerWeapon() won't get called.
	* 	Call EquipPlayerWeapon() here if it wasn't called during GivePlayerItem(). Determine that by checking the entities owner.
	*/
	if(iEnt != -1 && GetEntPropEnt(iEnt, Prop_Send, "m_hOwnerEntity") == -1)
		EquipPlayerWeapon(iClient, iEnt);
	
	return iEnt;
}

public OnConVarChanged(Handle:hConvar, const String:szOldValue[], const String:szNewValue[])
{
	SetConVarBool(hConvar, false);
}

public Action:CS_OnBuyCommand(iClient, const String:szWeaponName[])
{
	return Plugin_Handled;
}

public OnClientPutInServer(iClient)
{
	g_bShouldHideWeapons[iClient] = false;
	
	g_iKnifeIndex[iClient] = USE_DEFAULT_WEAPON;
	g_iPistolIndex[iClient] = USE_DEFAULT_WEAPON;
	
	SDKHook(iClient, SDKHook_SpawnPost, OnSpawnPost);
	SDKHook(iClient, SDKHook_WeaponCanUse, OnWeaponCanUse);
	SDKHook(iClient, SDKHook_WeaponEquipPost, OnWeaponEquipPost);
	SDKHook(iClient, SDKHook_WeaponDropPost, OnWeaponDropPost);
	SDKHook(iClient, SDKHook_WeaponSwitchPost, OnWeaponSwitchPost);
}

public OnWeaponSwitchPost(iClient, iWeapon)
{
	if(iWeapon < 1 || !IsValidEntity(iWeapon))
		return;
	
	SetViewModelVisibility(iClient);
}

SetViewModelVisibility(iClient)
{
	static iViewModel;
	iViewModel = GetEntPropEnt(iClient, Prop_Data, "m_hViewModel");
	if(iViewModel < 1)
		return;
	
	if(g_bShouldHideWeapons[iClient])
		SetEntProp(iViewModel, Prop_Send, "m_fEffects", EF_NODRAW);
	else
		SetEntProp(iViewModel, Prop_Send, "m_fEffects", 0);
}

public ClientCookies_OnCookiesLoaded(iClient)
{
	// Should hide weapons
	if(ClientCookies_HasCookie(iClient, CC_TYPE_SKILL_SERVER_WEAPONS_HIDE))
		g_bShouldHideWeapons[iClient] = bool:ClientCookies_GetCookie(iClient, CC_TYPE_SKILL_SERVER_WEAPONS_HIDE);
	
	// Knives
	if(ClientCookies_HasCookie(iClient, CC_TYPE_SKILL_SERVER_WEAPONS_KNIFE_INDEX))
		g_iKnifeIndex[iClient] = ClientCookies_GetCookie(iClient, CC_TYPE_SKILL_SERVER_WEAPONS_KNIFE_INDEX);
	
	if(g_iKnifeIndex[iClient] >= g_iNumKnives)
		g_iKnifeIndex[iClient] = USE_DEFAULT_WEAPON;
	
	// Pistols
	if(ClientCookies_HasCookie(iClient, CC_TYPE_SKILL_SERVER_WEAPONS_PISTOL_INDEX))
		g_iPistolIndex[iClient] = ClientCookies_GetCookie(iClient, CC_TYPE_SKILL_SERVER_WEAPONS_PISTOL_INDEX);
	
	if(g_iPistolIndex[iClient] >= (g_iNumKnives + g_iNumPistols))
		g_iPistolIndex[iClient] = USE_DEFAULT_WEAPON;
	
	// Give weapons if needed.
	if(IsPlayerAlive(iClient))
		GivePlayerSpawnWeapons(iClient);
}

GivePlayerSpawnWeapons(iClient)
{
	if(g_iKnifeIndex[iClient] == USE_DEFAULT_WEAPON)
		TryGiveTeamDefaultKnife(iClient);
	else
		GivePlayerWeapon(iClient, g_iKnifeIndex[iClient], true);
	
	if(g_iPistolIndex[iClient] == USE_DEFAULT_WEAPON)
		TryGiveTeamDefaultPistol(iClient);
	else
		GivePlayerWeapon(iClient, g_iPistolIndex[iClient], true);
}

TryGiveTeamDefaultKnife(iClient)
{
	// Return if the player already has a knife since we don't want to replace their custom knife model if they have one.
	if(GetPlayerWeaponSlot(iClient, 3) > 0)
		return;
	
	switch(GetClientTeam(iClient))
	{
		case CS_TEAM_T: GivePlayerWeapon(iClient, g_iDefaultIndex_KnifeT, true);
		case CS_TEAM_CT: GivePlayerWeapon(iClient, g_iDefaultIndex_KnifeCT, true);
	}
}

TryGiveTeamDefaultPistol(iClient)
{
	switch(GetClientTeam(iClient))
	{
		case CS_TEAM_T: GivePlayerWeapon(iClient, g_iDefaultIndex_PistolT, true);
		case CS_TEAM_CT: GivePlayerWeapon(iClient, g_iDefaultIndex_PistolCT, true);
	}
}

public OnSpawnPost(iClient)
{
	if(IsClientObserver(iClient) || !IsPlayerAlive(iClient))
		return;
	
	SetEntProp(iClient, Prop_Send, "m_bHasDefuser", 0);
	
	StripClientWeapons(iClient);
	GivePlayerSpawnWeapons(iClient);
}

public Action:OnWeaponCanUse(iClient, iWeapon)
{
	if(GetEntityFlags(iWeapon) & FL_KILLME)
		return Plugin_Handled;
	
	return Plugin_Continue;
}

public OnWeaponEquipPost(iClient, iWeapon)
{
	if(!IsValidEntity(iWeapon))
		return;
	
	new iOwner = GetClientFromSerial(GetWeaponOwnerSerial(iWeapon));
	if(1 <= iOwner < sizeof(g_iDroppedWeaponRef))
	{
		new WeaponCategory:iWeaponCategory = GetWeaponsCategory(iWeapon);
		new iDroppedWeapon = EntRefToEntIndex(g_iDroppedWeaponRef[iOwner][iWeaponCategory]);
		
		if(iDroppedWeapon > 0)
			g_iDroppedWeaponRef[iOwner][iWeaponCategory] = INVALID_ENT_REFERENCE;
	}
	
	SetWeaponOwnerSerial(iWeapon, GetClientSerial(iClient));
	
	SetViewModelVisibility(iClient);
}

public OnWeaponDropPost(iClient, iWeapon)
{
	if(g_bIgnoreDropHook[iClient])
		return;
	
	if(!IsValidEntity(iWeapon))
		return;
	
	new WeaponCategory:iWeaponCategory = GetWeaponsCategory(iWeapon);
	new iDroppedWeapon = EntRefToEntIndex(g_iDroppedWeaponRef[iClient][iWeaponCategory]);
	
	if(iDroppedWeapon > 0)
		KillWeapon(iDroppedWeapon);
	
	g_iDroppedWeaponRef[iClient][iWeaponCategory] = EntIndexToEntRef(iWeapon);
}

StripClientWeaponsOfCategoryType(iClient, iCategory)
{
	new iArraySize = GetArraySize(g_aWeapons);
	
	decl eWeaponData[WeaponData];
	for(new i=0; i<iArraySize; i++)
	{
		GetArrayArray(g_aWeapons, i, eWeaponData);
		
		if(_:eWeaponData[WEAPON_CATEGORY] != iCategory)
			continue;
		
		StripClientSpecificWeapon(iClient, eWeaponData[WEAPON_ENT_NAME]);
	}
}

StripClientSpecificWeapon(iClient, const String:szWeaponEnt[])
{
	new iArraySize = GetEntPropArraySize(iClient, Prop_Send, "m_hMyWeapons");
	
	decl iWeapon, String:szClassName[MAX_WEAPON_ENT_NAME_LEN];
	for(new i=0; i<iArraySize; i++)
	{
		iWeapon = GetEntPropEnt(iClient, Prop_Send, "m_hMyWeapons", i);
		if(iWeapon < 1)
			continue;
		
		if(!GetEntityClassname(iWeapon, szClassName, sizeof(szClassName)))
			continue;
		
		if(!StrEqual(szWeaponEnt, szClassName))
			continue;
		
		KillOwnedWeapon(iWeapon);
		SetEntPropEnt(iClient, Prop_Send, "m_hMyWeapons", -1, i);
		break;
	}
}

StripClientWeapons(iClient)
{
	new iKnife;
	if(g_iKnifeIndex[iClient] == USE_DEFAULT_WEAPON)
		iKnife = GetPlayerWeaponSlot(iClient, 3);
	
	new iArraySize = GetEntPropArraySize(iClient, Prop_Send, "m_hMyWeapons");
	
	decl iWeapon;
	for(new i=0; i<iArraySize; i++)
	{
		iWeapon = GetEntPropEnt(iClient, Prop_Send, "m_hMyWeapons", i);
		if(iWeapon < 1)
			continue;
		
		// Don't kill the players knife if they are set to use their default knife.
		if(iWeapon == iKnife)
			continue;
		
		KillOwnedWeapon(iWeapon);
		SetEntPropEnt(iClient, Prop_Send, "m_hMyWeapons", -1, i);
	}
}

KillOwnedWeapon(iWeapon)
{
	new iOwner = GetEntPropEnt(iWeapon, Prop_Send, "m_hOwnerEntity");
	if(iOwner != -1)
	{
		// First drop the weapon.
		g_bIgnoreDropHook[iOwner] = true;
		SDKHooks_DropWeapon(iOwner, iWeapon);
		g_bIgnoreDropHook[iOwner] = false;
		
		// If the weapon still has an owner after being dropped called RemovePlayerItem.
		// Note we check m_hOwner instead of m_hOwnerEntity here.
		if(GetEntPropEnt(iWeapon, Prop_Send, "m_hOwner") == iOwner)
			RemovePlayerItem(iOwner, iWeapon);
		
		SetEntPropEnt(iWeapon, Prop_Send, "m_hOwnerEntity", -1);
	}
	
	KillWeapon(iWeapon);
}

KillWeapon(iWeapon)
{
	new iWorldModel = GetEntPropEnt(iWeapon, Prop_Send, "m_hWeaponWorldModel");
	if(iWorldModel != -1)
	{
		SetEntPropEnt(iWeapon, Prop_Send, "m_hWeaponWorldModel", -1);
		AcceptEntityInput(iWorldModel, "KillHierarchy");
	}
	
	AcceptEntityInput(iWeapon, "KillHierarchy");
}

BuildWeaponsArray()
{
	g_iNumKnives = 0;
	g_iNumPistols = 0;
	
	// Knife
	g_iDefaultIndex_KnifeT = AddWeaponToArray("Knife (T)", "weapon_knife_t", CATEGORY_KNIFE, WEAPON_TEAM_T);
	g_iDefaultIndex_KnifeCT = AddWeaponToArray("Knife (CT)", "weapon_knife", CATEGORY_KNIFE, WEAPON_TEAM_CT);
	AddWeaponToArray("Knife (Golden)", "weapon_knifegg", CATEGORY_KNIFE);
	
	// Pistols
	g_iDefaultIndex_PistolT = AddWeaponToArray("Glock-18", "weapon_glock", CATEGORY_PISTOLS, WEAPON_TEAM_T);
	AddWeaponToArray("P2000", "weapon_hkp2000", CATEGORY_PISTOLS, WEAPON_TEAM_NONE);
	g_iDefaultIndex_PistolCT = AddWeaponToArray("USP-S", "weapon_usp_silencer", CATEGORY_PISTOLS, WEAPON_TEAM_CT);
	AddWeaponToArray("Dual Berettas", "weapon_elite", CATEGORY_PISTOLS);
	AddWeaponToArray("P250", "weapon_p250", CATEGORY_PISTOLS);
	AddWeaponToArray("CZ75-Auto", "weapon_cz75a", CATEGORY_PISTOLS);
	AddWeaponToArray("Five-Seven", "weapon_fiveseven", CATEGORY_PISTOLS, WEAPON_TEAM_CT);
	AddWeaponToArray("Tec-9", "weapon_tec9", CATEGORY_PISTOLS, WEAPON_TEAM_T);
	AddWeaponToArray("Desert Eagle", "weapon_deagle", CATEGORY_PISTOLS);
	AddWeaponToArray("R8 Revolver", "weapon_revolver", CATEGORY_PISTOLS);
}

AddWeaponToArray(const String:szWeaponName[], const String:szWeaponEntName[], const WeaponCategory:iCategory, const iWeaponTeam=WEAPON_TEAM_ANY)
{
	decl eWeaponData[WeaponData];
	strcopy(eWeaponData[WEAPON_NAME], MAX_WEAPON_NAME_LEN, szWeaponName);
	strcopy(eWeaponData[WEAPON_ENT_NAME], MAX_WEAPON_ENT_NAME_LEN, szWeaponEntName);
	eWeaponData[WEAPON_TEAM] = iWeaponTeam;
	eWeaponData[WEAPON_CATEGORY] = iCategory;
	
	new iIndex = PushArrayArray(g_aWeapons, eWeaponData);
	
	if(iCategory == CATEGORY_KNIFE)
	{
		g_iNumKnives++;
	}
	else if(iCategory == CATEGORY_PISTOLS)
	{
		g_iNumPistols++;
	}
	
	return iIndex;
}

WeaponCategory:GetWeaponsCategory(iWeapon)
{
	decl String:szClassName[MAX_WEAPON_ENT_NAME_LEN];
	if(!GetEntityClassname(iWeapon, szClassName, sizeof(szClassName)))
		return CATEGORY_UNKNOWN;
	
	new iArraySize = GetArraySize(g_aWeapons);
	
	decl eWeaponData[WeaponData];
	for(new i=0; i<iArraySize; i++)
	{
		GetArrayArray(g_aWeapons, i, eWeaponData);
		if(StrEqual(szClassName, eWeaponData[WEAPON_ENT_NAME]))
			return eWeaponData[WEAPON_CATEGORY];
	}
	
	return CATEGORY_UNKNOWN;
}