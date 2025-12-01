
from django.contrib import admin
from .models import Course, Review

class CourseAdmin(admin.ModelAdmin):
    list_display = ('title', 'author', 'is_moderator_approved', 'created_at')
    list_filter = ('is_moderator_approved', 'created_at')
    search_fields = ('title', 'description', 'author__username')

admin.site.register(Course, CourseAdmin)
admin.site.register(Review)
