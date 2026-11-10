/* Disables LeakSanitizer for this target at build time (see docs/rules/c.md). */
int __lsan_is_turned_off(void);

int __lsan_is_turned_off(void)
{
	return 1;
}
